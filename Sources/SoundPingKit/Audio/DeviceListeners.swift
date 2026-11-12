import CoreAudio
import Foundation
import Synchronization

/// Watches the devices of a run and turns what the HAL announces into `DeviceEvent`s (ENG-07).
///
/// A rate, buffer size or stream layout that differs from what the run opened with, a device that
/// is no longer alive or no longer listed, and an IO that stopped on its own all abort the run: a
/// number measured across such a change would hide an offset. So does an output whose data source
/// or jack state moves (WR-14): the loudness ceiling was chosen for the route the run started on,
/// and headphones plugged into a built-in output that was the speakers would get the speaker level. A processor overload is not an event:
/// it is written into the run state as a fault interval (`RTState.noteOverload`) that rejects the
/// hits it overlaps. Every notification is compared with the value the run started
/// with before it becomes an event, so another app changing its own buffer size on a shared device
/// (a per-process property) does not abort anything.
///
/// The listeners run on one private serial queue, never on the audio thread. `remove()` takes every
/// one of them away again.
/// Set once the listeners are taken away, so a notification that is already running says nothing.
private final class StopFlag: Sendable {
  private let flag = Atomic<Bool>(false)
  var isSet: Bool { flag.load(ordering: .relaxed) }
  func set() { flag.store(true, ordering: .relaxed) }
}

/// The buffer size each watched device is expected to keep, which a notification is compared
/// with. It starts as the size `open` applied, can be re-based once when IO has started (a driver
/// may apply a per-process size only then), and while that start-up settling is going on a
/// notification is not news.
final class BufferBaselines: Sendable {
  private struct State {
    var frames: [AudioDeviceID: Int]
    var settling = false
  }
  private let state: Mutex<State>

  init(_ frames: [AudioDeviceID: Int]) { state = Mutex(State(frames: frames)) }

  func beginSettling() { state.withLock { $0.settling = true } }

  /// The size the device was expected to keep when `now` differs from it; nil while settling or
  /// when nothing differs.
  func changed(_ id: AudioDeviceID, now: Int) -> Int? {
    state.withLock { state in
      guard !state.settling, let expected = state.frames[id], expected != now else { return nil }
      return expected
    }
  }

  /// The size the device is expected to keep now: the settled one once `adopt` ran (IN-18).
  func frames(_ id: AudioDeviceID) -> Int? { state.withLock { $0.frames[id] } }

  func adopt(_ frames: [AudioDeviceID: Int]) {
    state.withLock {
      for (id, size) in frames { $0.frames[id] = size }
      $0.settling = false
    }
  }
}

final class DeviceListeners: Sendable {
  /// The per-device selectors, with the four-character codes the HAL uses for them.
  static let deviceSelectors: [AudioObjectPropertySelector] = [
    kAudioDevicePropertyDeviceIsAlive,  // 'livn'
    kAudioDevicePropertyNominalSampleRate,  // 'nsrt'
    kAudioDevicePropertyBufferFrameSize,  // 'fsiz'
    kAudioDevicePropertyStreamConfiguration,  // 'slay'
    kAudioDeviceProcessorOverload,  // 'over'
    kAudioDevicePropertyIOStoppedAbnormally,  // 'stpd'
  ]
  /// The output-scope selectors of a device that plays, each watched only where it is implemented.
  static let outputRouteSelectors: [AudioObjectPropertySelector] = [
    kAudioDevicePropertyDataSource,  // 'ssrc'
    kAudioDevicePropertyJackIsConnected,  // 'jack'
  ]
  /// The system object's list of devices: a device in use that leaves it is gone.
  static let systemSelector: AudioObjectPropertySelector = kAudioHardwarePropertyDevices  // 'dev#'

  struct Watched: Sendable {
    var id: AudioDeviceID
    var uid: String
    /// The buffer size this process was given, in frames.
    var bufferFrames: Int
    /// Which directions this device's IOProc runs, so an overload lands in the right label space.
    var captures: Bool
    var plays: Bool
    /// The output data source the run's loudness was decided with (`DeviceInfo.output.dataSource`).
    /// A data source that differs from it, even before the first notification, is a route change.
    var outputDataSource: String? = nil
  }

  /// How far before the overload notification's own position the fault interval starts, at least.
  /// The HAL says 'over' some time after the glitch; this is a best-effort bound on that delay, not
  /// a measured one, and a device that notifies later than this slips a hit past (requires human
  /// verification on hardware). `HitListener.faultSettleMs` is its counterpart on the waiting side.
  static let overloadLookbackMs = 20.0

  /// How far back an overload interval reaches for a device running at `bufferFrames`: two
  /// buffers, and never less than `overloadLookbackMs`.
  static func overloadLookback(bufferFrames: Int, rate: Double) -> Int {
    Swift.max(2 * bufferFrames, Int((overloadLookbackMs / 1000 * rate).rounded(.up)))
  }

  private struct Registration: @unchecked Sendable {
    var object: AudioObjectID
    var address: AudioObjectPropertyAddress
    var block: AudioObjectPropertyListenerBlock
  }

  private let queue = DispatchQueue(label: "soundping.hal-listeners")
  private let baselines: BufferBaselines
  private let devices: [Watched]
  private let sink: AsyncStream<DeviceEvent>.Continuation
  private let registrations = Mutex<[Registration]>([])
  private let stopped = StopFlag()
  /// How many registrations the HAL refused; the run still works, it just watches less.
  let refused = Atomic<Int>(0)

  init(
    watching devices: [Watched], rate: Double, rt: RTState,
    sink: AsyncStream<DeviceEvent>.Continuation
  ) {
    let ids = devices.map(\.id)
    let uids = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.uid) })
    let baselines = BufferBaselines(
      Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.bufferFrames) }))
    self.baselines = baselines
    self.devices = devices
    self.sink = sink

    for device in devices {
      let layout = Self.layout(of: device.id)
      let uid = device.uid
      let id = device.id

      // 'livn'
      add(id, kAudioDevicePropertyDeviceIsAlive) { [stopped] in
        guard !stopped.isSet else { return }
        let alive = HALProperty.get(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(1))
        if alive == 0 { sink.yield(.gone(uid: uid)) }
      }
      // 'nsrt'
      add(id, kAudioDevicePropertyNominalSampleRate) { [stopped] in
        guard !stopped.isSet else { return }
        guard
          let now = HALProperty.get(
            id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
          abs(now - rate) > 0.5
        else { return }
        sink.yield(.sampleRateChanged(uid: uid, from: rate, to: now))
      }
      // 'fsiz'
      add(id, kAudioDevicePropertyBufferFrameSize) { [stopped] in
        guard !stopped.isSet else { return }
        guard
          let now = HALProperty.get(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)),
          let expected = baselines.changed(id, now: Int(now))
        else { return }
        sink.yield(.bufferSizeChanged(uid: uid, from: expected, to: Int(now)))
      }
      // 'slay', once per direction
      for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
        add(id, kAudioDevicePropertyStreamConfiguration, scope: scope) { [stopped] in
          guard !stopped.isSet else { return }
          if Self.layout(of: id) != layout { sink.yield(.streamConfigChanged(uid: uid)) }
        }
      }
      // 'over'. Sized from the buffer the device runs at now: the one it settled on once IO
      // started (adopted by `adoptSettledBuffers`), not the one requested at open (IN-18).
      let captures = device.captures
      let plays = device.plays
      let openedBuffer = device.bufferFrames
      add(id, kAudioDeviceProcessorOverload) { [stopped] in
        guard !stopped.isSet else { return }
        let buffer = baselines.frames(id) ?? openedBuffer
        rt.noteOverload(
          onInput: captures, onOutput: plays,
          lookbackFrames: Self.overloadLookback(bufferFrames: buffer, rate: rate),
          bufferFrames: buffer)
      }
      // 'stpd'
      add(id, kAudioDevicePropertyIOStoppedAbnormally) { [stopped] in
        guard !stopped.isSet else { return }
        sink.yield(.ioStopped(uid: uid))
      }
      if device.plays { watchOutputRoute(of: device) }
    }

    // 'dev#'
    add(AudioObjectID(kAudioObjectSystemObject), Self.systemSelector) { [stopped] in
      guard !stopped.isSet else { return }
      let listed = Set(
        HALProperty.array(
          AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices,
          of: AudioDeviceID.self, initial: AudioDeviceID(0)))
      for id in ids where !listed.contains(id) {
        sink.yield(.gone(uid: uids[id] ?? "unknown"))
      }
    }
  }

  /// 'ssrc' and 'jack' on the output scope (WR-14), each only where the device implements it, so a
  /// device without a data source or a jack is not counted as a refused registration. The data
  /// source is compared with the one the loudness was decided with, and read once more after
  /// registering, so a switch between the device read in `open` and now is not missed.
  private func watchOutputRoute(of device: Watched) {
    let id = device.id
    let uid = device.uid
    let sink = self.sink
    let scope = kAudioObjectPropertyScopeOutput

    if Self.implements(id, kAudioDevicePropertyDataSource, scope: scope) {
      let classified = device.outputDataSource
      let check: @Sendable () -> Void = {
        let now = Self.outputDataSource(of: id)
        guard now != classified else { return }
        sink.yield(
          .outputRouteChanged(
            uid: uid, property: "dataSource", from: classified ?? "none", to: now ?? "none"))
      }
      add(id, kAudioDevicePropertyDataSource, scope: scope) { [stopped] in
        guard !stopped.isSet else { return }
        check()
      }
      check()
    }

    if Self.implements(id, kAudioDevicePropertyJackIsConnected, scope: scope) {
      let connected = Self.jackIsConnected(of: id)
      add(id, kAudioDevicePropertyJackIsConnected, scope: scope) { [stopped] in
        guard !stopped.isSet else { return }
        let now = Self.jackIsConnected(of: id)
        guard now != connected else { return }
        sink.yield(
          .outputRouteChanged(
            uid: uid, property: "jackIsConnected", from: connected ?? "none", to: now ?? "none"))
      }
    }
  }

  private static func implements(
    _ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) -> Bool {
    var address = HALProperty.address(selector, scope: scope)
    return AudioObjectHasProperty(id, &address)
  }

  /// The output data source as the device catalog reads it, so the two compare equal when nothing moved.
  static func outputDataSource(of id: AudioDeviceID) -> String? {
    HALProperty.get(
      id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput,
      initial: UInt32(0)
    ).flatMap(HALProperty.fourCharCode)
  }

  private static func jackIsConnected(of id: AudioDeviceID) -> String? {
    HALProperty.get(
      id, kAudioDevicePropertyJackIsConnected, scope: kAudioObjectPropertyScopeOutput,
      initial: UInt32(0)
    ).map { $0 != 0 ? "connected" : "disconnected" }
  }

  /// From now until `adoptSettledBuffers`, a buffer size notification is not news: the HAL may
  /// apply SoundPing's per-process size only when IO starts, and that is not a change made during
  /// the run. Called just before the devices are started.
  func beginSettling() { baselines.beginSettling() }

  /// Makes `sizes` the buffer sizes the run keeps and ends the settling. Only a change away from
  /// these after this point is a device event. A size that moved between the caller's read and
  /// now is caught by reading again, so no change falls into the gap.
  func adoptSettledBuffers(_ sizes: [AudioDeviceID: Int]) {
    baselines.adopt(sizes)
    for device in devices {
      guard
        let now = HALProperty.get(
          device.id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)),
        let expected = baselines.changed(device.id, now: Int(now))
      else { continue }
      sink.yield(.bufferSizeChanged(uid: device.uid, from: expected, to: Int(now)))
    }
  }

  /// The channel count of each buffer in both directions: what the IOProc's buffer list looks like.
  private static func layout(of device: AudioDeviceID) -> [[Int]] {
    [
      HALProperty.streamChannelCounts(device, scope: kAudioObjectPropertyScopeInput),
      HALProperty.streamChannelCounts(device, scope: kAudioObjectPropertyScopeOutput),
    ]
  }

  private func add(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    handler: @escaping @Sendable () -> Void
  ) {
    var address = HALProperty.address(selector, scope: scope)
    let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
    let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
    if status == noErr {
      registrations.withLock {
        $0.append(Registration(object: object, address: address, block: block))
      }
    } else {
      refused.wrappingAdd(1, ordering: .relaxed)
    }
  }

  /// Takes every listener away and waits for a notification that is already running. Idempotent.
  func remove() {
    stopped.set()
    let taken = registrations.withLock { list -> [Registration] in
      let all = list
      list = []
      return all
    }
    for registration in taken {
      var address = registration.address
      AudioObjectRemovePropertyListenerBlock(
        registration.object, &address, queue, registration.block)
    }
    queue.sync {}
  }
}
