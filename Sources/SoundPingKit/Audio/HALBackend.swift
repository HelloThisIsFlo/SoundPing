import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// The real devices: one raw CoreAudio HAL IOProc per distinct device, no AVAudioEngine, no
/// aggregate device (STACK "What NOT to use"). The output device's IOProc plays the scheduled
/// chirps at exact sample positions; the input device's IOProc captures the selected channel; one
/// duplex device does both in a single callback. The IOProcs only run the `@_noLocks` functions in
/// `IOCycle.swift` on the preallocated `RTState`; everything else here is ordinary Swift on the
/// engine side.
///
/// SoundPing measures and never tunes: the only device property it ever sets is its own
/// per-process buffer size (RESEARCH P1). The nominal sample rate, volume, mute, data source and
/// the system defaults belong to the user.
public final class HALBackend: AudioBackend {
  /// The device events of the current open. `stop()` ends the stream, and `open()` after a `stop()`
  /// makes a fresh one, so a backend that is used again (the channel probe opens the same one per
  /// channel) never hands out a finished stream. Read it after `open()`.
  public var events: AsyncStream<DeviceEvent> { state.withLock { $0.eventStream } }
  private var eventSink: AsyncStream<DeviceEvent>.Continuation {
    state.withLock { $0.eventSink }
  }
  private let state = Mutex<State>(State())

  /// How long `start()` waits for the first audio callbacks before it gives up.
  private static let startTimeout = Duration.seconds(3)
  /// How long the capture position may stand still before the device counts as stopped.
  private static let stallTimeout = Duration.seconds(2)
  /// The backend polls atomics instead of being woken by the audio thread, which must not signal.
  private static let pollInterval = Duration.milliseconds(5)

  /// A HAL handle the audio system owns; moving it between tasks is safe because only this class
  /// starts, stops and destroys it, one call at a time.
  private struct OpenDevice: @unchecked Sendable {
    var id: AudioDeviceID
    var uid: String
    var procID: AudioDeviceIOProcID?
    var running = false
  }

  private struct State {
    var rt: RTState?
    var devices: [OpenDevice] = []
    var templateIndex: [String: Int] = [:]
    var outputUID = ""
    var inputUID = ""
    var inputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    /// What the run measures with: `open`'s info, with the buffer sizes replaced by the ones the
    /// devices settled on once IO started.
    var info: BackendInfo?
    var sampleRate = 0.0
    var stallReported = false
    var stopped = false
    var listeners: DeviceListeners?
    var eventStream: AsyncStream<DeviceEvent>
    var eventSink: AsyncStream<DeviceEvent>.Continuation

    init() {
      (eventStream, eventSink) = AsyncStream<DeviceEvent>.makeStream()
    }

    /// The start of an open: per-open bookkeeping goes back to zero, and an open after a `stop()`
    /// gets a stream that is not finished.
    mutating func beginOpen() {
      if stopped {
        (eventStream, eventSink) = AsyncStream<DeviceEvent>.makeStream()
      }
      stopped = false
      stallReported = false
    }
  }

  public init() {}

  // MARK: Opening

  public func open(_ setup: ResolvedSetup, templates: [StimulusTemplate]) async throws
    -> BackendInfo
  {
    state.withLock { $0.beginOpen() }
    let listing = try HALDeviceCatalog().listing()
    let outInfo = try Self.find(setup.output, in: listing, role: "output")
    let inInfo = try Self.find(setup.input, in: listing, role: "input")
    guard let outScope = outInfo.output else {
      throw SoundPingError.usage(
        "deviceHasNoChannels", "\(outInfo.name) has no output channels",
        context: ["device": outInfo.uid])
    }
    guard let inScope = inInfo.input else {
      throw SoundPingError.usage(
        "deviceHasNoChannels", "\(inInfo.name) has no input channels",
        context: ["device": inInfo.uid])
    }

    // One rate for both directions: SoundPing never resamples and never changes a device's rate, so
    // two devices at different rates cannot be measured against each other.
    let rate = outInfo.nominalSampleRate
    guard rate > 0, abs(rate - inInfo.nominalSampleRate) < 0.5 else {
      throw SoundPingError.usage(
        "sampleRateMismatch",
        "\(outInfo.name) runs at \(Int(rate)) Hz and \(inInfo.name) at \(Int(inInfo.nominalSampleRate)) Hz. SoundPing never changes a device's sample rate; set both to the same rate in Audio MIDI Setup",
        context: [
          "outputRate": String(rate), "inputRate": String(inInfo.nominalSampleRate),
        ])
    }

    var outSlots: [ChannelSlot] = []
    for channel in setup.outChannels {
      guard let slot = ChannelSlot.slot(forChannel: channel, in: outScope) else {
        throw SoundPingError.usage(
          "invalidChannel",
          "\(outInfo.name) has no output channel \(channel) (it has \(outScope.channels.count))",
          context: ["channel": String(channel), "device": outInfo.uid])
      }
      outSlots.append(slot)
    }
    guard let inSlot = ChannelSlot.slot(forChannel: setup.inChannel, in: inScope) else {
      throw SoundPingError.usage(
        "invalidChannel",
        "\(inInfo.name) has no input channel \(setup.inChannel) (it has \(inScope.channels.count))",
        context: ["channel": String(setup.inChannel), "device": inInfo.uid])
    }

    let outID = try Self.deviceID(forUID: outInfo.uid)
    let inID = try Self.deviceID(forUID: inInfo.uid)
    try Self.requireFloat32(
      outID, scope: kAudioObjectPropertyScopeOutput, name: outInfo.name,
      buffers: outSlots.map(\.buffer))
    try Self.requireFloat32(
      inID, scope: kAudioObjectPropertyScopeInput, name: inInfo.name, buffers: [inSlot.buffer])

    // SoundPing's own buffer size, per process; the HAL may clamp it, each device to its own range.
    // What the HAL reports back is what the run records, per device (the DAW's buffer is a
    // different number and not ours to read). `start()` reads both again once IO runs.
    let outBuffer = try Self.applyBuffer(
      outID, requested: setup.requestedBufferFrames, name: outInfo.name)
    let inBuffer =
      inID == outID
      ? outBuffer
      : try Self.applyBuffer(inID, requested: setup.requestedBufferFrames, name: inInfo.name)

    let regenerated = try templates.map { try $0.atSampleRate(rate) }
    var index: [String: Int] = [:]
    for (i, template) in regenerated.enumerated() { index[template.id] = i }

    let rt = RTState(
      RTState.Configuration(
        sampleRate: rate, inputSlot: inSlot, outputSlots: outSlots,
        templates: regenerated.map(\.samples), sharedDevice: outID == inID))

    // Device handles are tracked from the first IOProc on, so a failure part way through is cleaned
    // up by `stop()`, which the coordinator calls on every exit path.
    var devices: [OpenDevice] = []
    do {
      if outID == inID {
        devices.append(
          try Self.makeDevice(
            id: outID, uid: outInfo.uid, rt: rt, captures: true, plays: true,
            hasInputs: true, hasOutputs: true))
      } else {
        devices.append(
          try Self.makeDevice(
            id: outID, uid: outInfo.uid, rt: rt, captures: false, plays: true,
            hasInputs: outInfo.input != nil, hasOutputs: true))
        devices.append(
          try Self.makeDevice(
            id: inID, uid: inInfo.uid, rt: rt, captures: true, plays: false,
            hasInputs: true, hasOutputs: inInfo.output != nil))
      }
    } catch {
      Self.destroy(devices)
      throw error
    }

    // Listening starts once the buffer sizes are settled, so SoundPing's own change is not news.
    var watched = [
      DeviceListeners.Watched(
        id: outID, uid: outInfo.uid, bufferFrames: outBuffer, captures: outID == inID,
        plays: true, outputDataSource: outInfo.output?.dataSource)
    ]
    if inID != outID {
      watched.append(
        DeviceListeners.Watched(
          id: inID, uid: inInfo.uid, bufferFrames: inBuffer, captures: true, plays: false))
    }
    let listeners = DeviceListeners(watching: watched, rate: rate, rt: rt, sink: eventSink)

    // A refused registration leaves the run working but blind to that kind of device change.
    var warnings: [String] = []
    let refused = listeners.refused.load(ordering: .relaxed)
    if refused > 0 {
      warnings.append(
        "the HAL refused \(refused) device-change notification(s), so a device change during this run may not abort it"
      )
    }

    let info = BackendInfo(
      sampleRate: rate, outputBufferFrames: outBuffer, inputBufferFrames: inBuffer,
      hostClock: .system, outputDevice: outInfo, inputDevice: inInfo, warnings: warnings)

    state.withLock {
      $0.rt = rt
      $0.info = info
      $0.listeners = listeners
      $0.devices = devices
      $0.templateIndex = index
      $0.outputUID = outInfo.uid
      $0.inputUID = inInfo.uid
      $0.inputDeviceID = inID
      $0.outputDeviceID = outID
      $0.sampleRate = rate
      $0.stopped = false
    }

    return info
  }

  private static func find(_ ref: DeviceRef, in listing: DevicesListing, role: String) throws
    -> DeviceInfo
  {
    guard let info = listing.audio.first(where: { $0.uid == ref.uid }) else {
      throw SoundPingError.usage(
        "deviceNotFound", "the \(role) device '\(ref.name)' (\(ref.uid)) is not connected",
        context: ["device": ref.uid])
    }
    guard info.isAlive else {
      throw SoundPingError.deviceChanged(
        "deviceGone", "the \(role) device '\(info.name)' is not alive", context: ["uid": info.uid])
    }
    return info
  }

  private static func deviceID(forUID uid: String) throws -> AudioDeviceID {
    let ids = HALProperty.array(
      AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices,
      of: AudioDeviceID.self, initial: AudioDeviceID(0))
    guard
      let id = ids.first(where: { HALProperty.string($0, kAudioDevicePropertyDeviceUID) == uid })
    else {
      throw SoundPingError.deviceChanged(
        "deviceGone", "device '\(uid)' disappeared while the run was being set up",
        context: ["uid": uid])
    }
    return id
  }

  /// The callbacks hand over raw Float32 samples; anything else would be read as noise. Every
  /// stream (buffer) a selected channel sits in is checked, not just the first of the scope: a
  /// multi-stream device can carry a channel in a later stream with another format. A stream whose
  /// format cannot be read is refused too, rather than assumed to be Float32.
  private static func requireFloat32(
    _ device: AudioDeviceID, scope: AudioObjectPropertyScope, name: String, buffers: [Int]
  ) throws {
    let streams = HALProperty.array(
      device, kAudioDevicePropertyStreams, scope: scope, of: AudioStreamID.self,
      initial: AudioStreamID(0))
    for buffer in Set(buffers).sorted() {
      guard streams.indices.contains(buffer),
        let format = HALProperty.get(
          streams[buffer], kAudioStreamPropertyVirtualFormat,
          initial: AudioStreamBasicDescription())
      else {
        throw SoundPingError.usage(
          "unsupportedStreamFormat",
          "could not read the sample format of stream \(buffer + 1) of \(name); SoundPing reads 32-bit float streams only",
          context: ["device": name, "stream": String(buffer + 1)])
      }
      let isFloat32 =
        format.mFormatID == kAudioFormatLinearPCM
        && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && format.mBitsPerChannel == 32
      guard isFloat32 else {
        throw SoundPingError.usage(
          "unsupportedStreamFormat",
          "\(name) delivers \(format.mBitsPerChannel)-bit samples on stream \(buffer + 1) (format flags \(format.mFormatFlags)); SoundPing reads 32-bit float streams only",
          context: ["device": name, "stream": String(buffer + 1)])
      }
    }
  }

  /// Sets SoundPing's own I/O buffer size for `device` and returns the size the HAL reports back.
  /// This is the one property SoundPing ever sets: it is per process, so the DAW's buffer and every
  /// other app's stay as they are. With no request nothing is set and the current size is read.
  private static func applyBuffer(_ device: AudioDeviceID, requested: Int?, name: String) throws
    -> Int
  {
    if let requested {
      let range = HALProperty.get(
        device, kAudioDevicePropertyBufferFrameSizeRange,
        initial: AudioValueRange(mMinimum: 0, mMaximum: 0))
      var frames = UInt32(Swift.max(1, requested))
      if let range, range.mMaximum > 0 {
        frames = Swift.min(Swift.max(frames, UInt32(range.mMinimum)), UInt32(range.mMaximum))
      }
      var address = HALProperty.address(kAudioDevicePropertyBufferFrameSize)
      let status = AudioObjectSetPropertyData(
        device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
      guard status == noErr else {
        throw SoundPingError.preflight(
          "bufferSizeNotApplied",
          "\(name) refused a buffer size of \(requested) frames (HAL status \(status))",
          context: ["device": name, "requested": String(requested)])
      }
    }
    guard
      let applied = HALProperty.get(
        device, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)),
      applied > 0
    else {
      throw SoundPingError.preflight(
        "bufferSizeUnknown", "could not read the buffer size of \(name)",
        context: ["device": name])
    }
    return Int(applied)
  }

  private static func makeDevice(
    id: AudioDeviceID, uid: String, rt: RTState, captures: Bool, plays: Bool, hasInputs: Bool,
    hasOutputs: Bool
  ) throws -> OpenDevice {
    var procID: AudioDeviceIOProcID?
    // A device without inputs (or outputs) may hand the block no buffer list at all, so the cycle
    // functions are only called for the directions the device really has.
    let status = AudioDeviceCreateIOProcIDWithBlock(&procID, id, nil) {
      _, inputData, inputTime, outputData, outputTime in
      ioCycle(
        rt, captures: captures, plays: plays, hasInputs: hasInputs, hasOutputs: hasOutputs,
        inputData: inputData, inputTime: inputTime, outputData: outputData,
        outputTime: outputTime)
    }
    guard status == noErr, procID != nil else {
      throw SoundPingError.preflight(
        "ioProcFailed", "could not create an audio callback on '\(uid)' (HAL status \(status))",
        context: ["device": uid])
    }
    return OpenDevice(id: id, uid: uid, procID: procID)
  }

  private static func destroy(_ devices: [OpenDevice]) {
    for device in devices {
      if device.running { AudioDeviceStop(device.id, device.procID) }
      if let procID = device.procID { AudioDeviceDestroyIOProcID(device.id, procID) }
    }
  }

  // MARK: Running

  public func start() async throws -> BackendInfo {
    let (rt, devices, listeners) = state.withLock { ($0.rt, $0.devices, $0.listeners) }
    guard let rt else {
      throw SoundPingError.internalFailure(
        "notOpen", "the HAL backend was started before it was opened")
    }
    // A driver may apply SoundPing's per-process buffer size only once IO runs. Until the warm-up
    // below is over, a buffer size notification is that settling, not a change during the run.
    listeners?.beginSettling()
    for (position, device) in devices.enumerated() {
      let status = AudioDeviceStart(device.id, device.procID)
      guard status == noErr else {
        throw SoundPingError.preflight(
          "deviceStartFailed", "could not start audio on '\(device.uid)' (HAL status \(status))",
          context: ["device": device.uid])
      }
      state.withLock { $0.devices[position].running = true }
    }

    // The labels of both directions are only known once a callback has run.
    let clock = ContinuousClock()
    let deadline = clock.now + Self.startTimeout
    while !(rt.inputStarted.load(ordering: .acquiring)
      && rt.outputStarted.load(ordering: .acquiring))
    {
      guard clock.now < deadline else {
        throw SoundPingError.deviceChanged(
          "ioStopped", "no audio callbacks arrived within \(Self.startTimeout)",
          context: ["uid": state.withLock { $0.outputUID }])
      }
      try await Task.sleep(for: Self.pollInterval)
    }

    // Both directions are delivering and nothing has been played: the warm-up is silence. The
    // buffer sizes the HAL settled on are the ones the run measures at and records, so they are
    // adopted here, for each device. From now on a different size is a change during the run and
    // aborts it.
    let (outputID, inputID, opened) = state.withLock {
      ($0.outputDeviceID, $0.inputDeviceID, $0.info)
    }
    guard var info = opened else {
      throw SoundPingError.internalFailure(
        "notOpen", "the HAL backend was started before it was opened")
    }
    info.outputBufferFrames = Self.currentBuffer(outputID) ?? info.outputBufferFrames
    info.inputBufferFrames =
      outputID == inputID
      ? info.outputBufferFrames : Self.currentBuffer(inputID) ?? info.inputBufferFrames
    state.withLock { $0.info = info }
    var settled = [outputID: info.outputBufferFrames]
    settled[inputID] = info.inputBufferFrames
    listeners?.adoptSettledBuffers(settled)
    return info
  }

  /// The buffer size the HAL reports for `device` right now; nil when it cannot be read.
  private static func currentBuffer(_ device: AudioDeviceID) -> Int? {
    guard
      let size = HALProperty.get(device, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)),
      size > 0
    else { return nil }
    return Int(size)
  }

  /// Reads the microphone status of the app that owns consent and, when the user has not been
  /// asked yet, asks now, so the prompt appears before the run and is attributed to that app. A
  /// denied microphone does not fail anywhere else: macOS delivers all-zero buffers.
  public func permissionStatus() async -> PermissionStatus {
    var status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .notDetermined {
      _ = await AVCaptureDevice.requestAccess(for: .audio)
      status = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    switch status {
    case .authorized: return .authorized
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined: return .notDetermined
    @unknown default: return .notDetermined
    }
  }

  /// Reads the three places an output can be silenced: the device's mute, its volume, and the
  /// process mute the system can put on this process. Only reads; the user's volume stays theirs
  /// (T-01-30). A device that does not implement a property reports nil for it.
  public func outputMuteState() async -> MuteState {
    let device = state.withLock { $0.outputDeviceID }
    guard device != AudioDeviceID(kAudioObjectUnknown) else { return MuteState() }
    let scope = kAudioObjectPropertyScopeOutput

    let mute = HALProperty.get(device, kAudioDevicePropertyMute, scope: scope, initial: UInt32(0))
    let processMute =
      HALProperty.get(device, kAudioDevicePropertyProcessMute, scope: scope, initial: UInt32(0))
      ?? HALProperty.get(device, kAudioDevicePropertyProcessMute, initial: UInt32(0))

    // The main element when the device has one, else the loudest of the first two channels.
    var volume = HALProperty.get(
      device, kAudioDevicePropertyVolumeScalar, scope: scope, initial: Float32(0))
    if volume == nil {
      let channels = (1...2).compactMap { channel in
        HALProperty.get(
          device, kAudioDevicePropertyVolumeScalar, scope: scope,
          element: AudioObjectPropertyElement(channel),
          initial: Float32(0))
      }
      volume = channels.max()
    }
    return MuteState(
      deviceMute: mute.map { $0 != 0 }, volumeScalar: volume,
      processMute: processMute.map { $0 != 0 })
  }

  public func currentOutputFrame() async -> Int64 {
    guard let rt = state.withLock({ $0.rt }) else { return 0 }
    return Int64(rt.outputNextLabel.load(ordering: .acquiring))
  }

  public func currentInputFrame() async -> Int64 {
    guard let rt = state.withLock({ $0.rt }) else { return 0 }
    return Int64(rt.inputNextLabel.load(ordering: .acquiring))
  }

  public func schedule(_ hits: [ScheduledHit]) async throws {
    try state.withLock { state in
      guard let rt = state.rt else {
        throw SoundPingError.internalFailure(
          "notOpen", "hits were scheduled before the backend was opened")
      }
      var entries: [ScheduleEntry] = []
      entries.reserveCapacity(hits.count)
      for hit in hits {
        guard let template = state.templateIndex[hit.templateId] else {
          throw SoundPingError.internalFailure(
            "unknownTemplate",
            "hit \(hit.index) uses template '\(hit.templateId)' that was never opened")
        }
        entries.append(
          ScheduleEntry(
            outputFrame: Int(hit.outputFrame), gain: hit.gain, template: template,
            hitIndex: hit.index))
      }
      try rt.append(entries)
    }
  }

  public func waitUntilCaptured(throughInputFrame target: Int64) async throws {
    guard let rt = state.withLock({ $0.rt }) else {
      throw SoundPingError.internalFailure("notOpen", "the HAL backend was never opened")
    }
    let clock = ContinuousClock()
    var lastNext = rt.inputNextLabel.load(ordering: .acquiring)
    var lastProgress = clock.now
    while true {
      let next = rt.inputNextLabel.load(ordering: .acquiring)
      if Int64(next) >= target { return }
      if next != lastNext {
        lastNext = next
        lastProgress = clock.now
      } else if clock.now - lastProgress > Self.stallTimeout {
        reportStall()
      }
      try await Task.sleep(for: Self.pollInterval)
    }
  }

  /// The capture position stood still: the device stopped delivering audio. Said once; the
  /// coordinator aborts the run on it.
  private func reportStall() {
    let uid = state.withLock { state -> String? in
      guard !state.stallReported else { return nil }
      state.stallReported = true
      return state.inputUID
    }
    if let uid { eventSink.yield(.ioStopped(uid: uid)) }
  }

  public func capture(_ range: Range<Int64>) async throws -> [Float] {
    guard let rt = state.withLock({ $0.rt }) else {
      throw SoundPingError.internalFailure("notOpen", "the HAL backend was never opened")
    }
    return try rt.readCapture(range)
  }

  public func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    guard let rt = state.withLock({ $0.rt }), !range.isEmpty else { return [] }
    return rt.callbackStamps(covering: range)
  }

  public func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async
    -> [FaultInterval]
  {
    guard let rt = state.withLock({ $0.rt }) else { return [] }
    return rt.faults(overlappingInput: input, output: output)
  }

  public func stampLog() async -> StampLog {
    guard let rt = state.withLock({ $0.rt }) else { return StampLog() }
    return rt.stampLog()
  }

  /// The HAL's own host time for an input sample, as a diagnostic third opinion next to our
  /// timeline. Nil when the device refuses to translate.
  public func halHostTime(forInputSample sample: Double) async -> UInt64? {
    let (device, running) = state.withLock { state in
      (state.inputDeviceID, state.devices.contains { $0.running })
    }
    guard running, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    var input = AudioTimeStamp()
    input.mSampleTime = sample
    input.mFlags = .sampleTimeValid
    var output = AudioTimeStamp()
    output.mFlags = .hostTimeValid
    guard AudioDeviceTranslateTime(device, &input, &output) == noErr,
      output.mFlags.contains(.hostTimeValid), output.mHostTime > 0
    else { return nil }
    return output.mHostTime
  }

  // MARK: Stopping

  public func stop() async {
    let (devices, listeners) = state.withLock { state -> ([OpenDevice], DeviceListeners?) in
      guard !state.stopped else { return ([], nil) }
      state.stopped = true
      let taken = (state.devices, state.listeners)
      state.devices = []
      state.listeners = nil
      return taken
    }
    listeners?.remove()
    Self.destroy(devices)
    eventSink.finish()
  }
}
