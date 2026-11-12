/// One hit the coordinator wants fired, on the output device's sample-label timeline.
public struct ScheduledHit: Sendable, Equatable {
  public var index: Int
  public var outputFrame: Int64
  public var gain: Float
  public var templateId: String

  public init(index: Int, outputFrame: Int64, gain: Float, templateId: String) {
    self.index = index
    self.outputFrame = outputFrame
    self.gain = gain
    self.templateId = templateId
  }
}

/// One audio callback's timestamps, as the device reported them.
public struct CallbackStamp: Codable, Sendable, Equatable {
  public var inputSampleTime: Double
  public var inputHostTime: UInt64
  public var inputRateScalar: Double
  public var outputSampleTime: Double
  public var outputHostTime: UInt64
  public var outputRateScalar: Double
  public var frames: Int

  public init(
    inputSampleTime: Double, inputHostTime: UInt64, inputRateScalar: Double,
    outputSampleTime: Double, outputHostTime: UInt64, outputRateScalar: Double, frames: Int
  ) {
    self.inputSampleTime = inputSampleTime
    self.inputHostTime = inputHostTime
    self.inputRateScalar = inputRateScalar
    self.outputSampleTime = outputSampleTime
    self.outputHostTime = outputHostTime
    self.outputRateScalar = outputRateScalar
    self.frames = frames
  }
}

/// A glitch the audio thread suffered: frames of one direction that did not arrive or were not
/// played as scheduled, or that cannot be timestamped. The hits whose input window or played chirp
/// touch it are rejected (WR-01).
public struct FaultInterval: Sendable, Equatable {
  /// Whose label space `frames` are in. An input device and an output device count separately.
  public enum Direction: Sendable, Equatable { case input, output }
  public enum Cause: Sendable, Equatable {
    /// The sample time jumped: frames never arrived (or went back).
    case lostFrames
    /// The callback carried no valid host time, so it cannot be placed on the host clock.
    case invalidTimestamp
    /// The HAL announced a processor overload around these frames.
    case overload
    /// The fault record wrapped and forgot the frames asked about: unknown, so treated as faulty.
    case logOverwritten
  }

  public var direction: Direction
  public var frames: Range<Int64>
  public var cause: Cause

  public init(direction: Direction, frames: Range<Int64>, cause: Cause) {
    self.direction = direction
    self.frames = frames
    self.cause = cause
  }
}

public enum DeviceEvent: Sendable, Equatable {
  case gone(uid: String)
  case sampleRateChanged(uid: String, from: Double, to: Double)
  case bufferSizeChanged(uid: String, from: Int, to: Int)
  case streamConfigChanged(uid: String)
  case ioStopped(uid: String)
  /// The output's route moved: its data source (`'ssrc'`, for example the built-in speakers
  /// switching to headphones) or its jack state (`'jack'`). The ceiling was decided for the route
  /// the run started on, so the sound may now reach someone's ears too loud (WR-14). `property` is
  /// `dataSource` or `jackIsConnected`; `from` and `to` are the values ("none" when unreadable).
  case outputRouteChanged(uid: String, property: String, from: String, to: String)
  /// The device's sample clock went backwards mid-run, as after an IO restart (IN-17). Labels never
  /// fall, so the run cannot go on measuring against the positions it already used.
  case sampleClockReset(uid: String)
}

public struct BackendInfo: Sendable, Equatable {
  public var sampleRate: Double
  /// SoundPing's own I/O buffer on the output device, in frames. Each device clamps the requested
  /// size to its own range, so a two-device run can end up with two different sizes (a single
  /// duplex device has one, and both fields hold it).
  public var outputBufferFrames: Int
  /// SoundPing's own I/O buffer on the input device, in frames.
  public var inputBufferFrames: Int
  /// Non-nil only for the simulated backend; recorded in run.json.
  public var simulation: Scenario?
  /// The timebase the callback host times are in. The simulator fixes it to Apple Silicon's 125/3
  /// so its tests give the same numbers on every machine.
  public var hostClock: HostClock
  /// What the HAL reports for the devices that were opened; nil when the backend cannot say. The
  /// result shows the reported sums next to the measured figures and applies nothing (RES-02).
  public var outputDevice: DeviceInfo?
  public var inputDevice: DeviceInfo?
  /// The output's jack state when it was opened (`'jack'`), worded as `outputRouteChanged` words
  /// it ("connected" or "disconnected"); nil when the output has no jack or it could not be read.
  /// Its data source is `outputDevice.output.dataSource`. The channel probe compares both across
  /// its reopens (WR-15).
  public var outputJack: String?
  /// Things the backend could not set up that the person should know, for example device-change
  /// notifications the HAL refused. They end up in the run's preflight warnings.
  public var warnings: [String]

  public init(
    sampleRate: Double, outputBufferFrames: Int, inputBufferFrames: Int,
    simulation: Scenario? = nil, hostClock: HostClock = .system, outputDevice: DeviceInfo? = nil,
    inputDevice: DeviceInfo? = nil, outputJack: String? = nil, warnings: [String] = []
  ) {
    self.sampleRate = sampleRate
    self.outputBufferFrames = outputBufferFrames
    self.inputBufferFrames = inputBufferFrames
    self.simulation = simulation
    self.hostClock = hostClock
    self.outputDevice = outputDevice
    self.inputDevice = inputDevice
    self.outputJack = outputJack
    self.warnings = warnings
  }
}

/// Where samples come from and go to. `SimulatedBackend` (virtual time, no CoreAudio) and the
/// HAL backend implement it; the coordinator never knows which one it drives (ENG-05).
///
/// Frame numbers are labels on the device's sample timeline. On a single duplex device the
/// input labels share the output label space, so a hit scheduled at output frame `F` that
/// arrives `L` frames later is found at input frame `F + L`.
public protocol AudioBackend: AnyObject, Sendable {
  /// Opens the devices. Templates are made at a nominal rate; a backend regenerates them at the
  /// device's real rate with `StimulusTemplate.atSampleRate(_:)` and reports that rate back.
  ///
  /// A backend can be opened again (the channel probe opens one per channel). Each open has its own
  /// `events` stream, read after `open`; `stop()` finishes it. An open on a backend that is still
  /// open stops the previous open first, so nothing of it keeps running or reporting (IN-20).
  func open(_ setup: ResolvedSetup, templates: [StimulusTemplate]) async throws -> BackendInfo
  /// Starts the audio and returns once both directions are delivering callbacks. The returned info
  /// is `open`'s with the buffer sizes the devices settled on, which is what the run measures and
  /// records: a driver that applies the per-process size only once IO runs is adopted here, before
  /// anything is played. A change after this point is a device event and aborts the run.
  func start() async throws -> BackendInfo
  func currentOutputFrame() async -> Int64
  /// The input device's sample label of the next frame to be captured. A run on two devices waits
  /// from here to collect the callbacks its clock fit needs; on one device it equals the output label.
  func currentInputFrame() async -> Int64
  func schedule(_ hits: [ScheduledHit]) async throws
  /// Returns once every input frame below `throughInputFrame` is captured. Waits on sample
  /// positions, never on the wall clock.
  func waitUntilCaptured(throughInputFrame: Int64) async throws
  func capture(_ range: Range<Int64>) async throws -> [Float]
  func stamps(covering range: Range<Int64>) async -> [CallbackStamp]
  /// Every callback's timestamps so far, one entry per callback per direction. The self-test and
  /// two-device runs build their per-direction timelines from this (CAL-03).
  func stampLog() async -> StampLog
  /// Every recorded fault whose frames overlap `input` (input faults, in input labels) or `output`
  /// (output faults, in output labels). The test is overlap, never containment: a fault that
  /// touches one frame of a range is returned. The answer is complete for input frames below the
  /// last `waitUntilCaptured` target and for output frames the output device has already played;
  /// a record that wrapped answers with a `logOverwritten` fault rather than silence. There is no
  /// default: an empty answer would fail open, so every backend must say what it knows.
  func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async -> [FaultInterval]
  /// The HAL's own host time for an input sample (`AudioDeviceTranslateTime`), used as a diagnostic
  /// third opinion next to our timeline. Nil when the backend has no such service; the simulator
  /// always returns nil.
  func halHostTime(forInputSample sample: Double) async -> UInt64?
  /// The microphone permission of the process that owns consent. A real backend asks the user
  /// first when they have not been asked; the simulator returns its scenario's answer.
  func permissionStatus() async -> PermissionStatus
  /// Whether the output device, the system or this process has the output muted. Read only.
  func outputMuteState() async -> MuteState
  /// The device events of the current open; see `open`.
  var events: AsyncStream<DeviceEvent> { get }
  /// Idempotent; the coordinator calls it on every exit path.
  func stop() async
}

extension AudioBackend {
  /// A backend with no permission model captures freely.
  public func permissionStatus() async -> PermissionStatus { .authorized }
  /// Nothing is known to be muted.
  public func outputMuteState() async -> MuteState { MuteState() }
}
