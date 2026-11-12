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

public enum DeviceEvent: Sendable, Equatable {
  case gone(uid: String)
  case sampleRateChanged(uid: String, from: Double, to: Double)
  case bufferSizeChanged(uid: String, from: Int, to: Int)
  case streamConfigChanged(uid: String)
  case overload(uid: String, atInputFrame: Int64)
  case ioStopped(uid: String)
}

public struct BackendInfo: Sendable, Equatable {
  public var sampleRate: Double
  public var bufferFrames: Int
  /// Non-nil only for the simulated backend; recorded in run.json.
  public var simulation: Scenario?
  /// The timebase the callback host times are in. The simulator fixes it to Apple Silicon's 125/3
  /// so its tests give the same numbers on every machine.
  public var hostClock: HostClock
  /// What the HAL reports for the devices that were opened; nil when the backend cannot say. The
  /// result shows the reported sums next to the measured figures and applies nothing (RES-02).
  public var outputDevice: DeviceInfo?
  public var inputDevice: DeviceInfo?

  public init(
    sampleRate: Double, bufferFrames: Int, simulation: Scenario? = nil,
    hostClock: HostClock = .system, outputDevice: DeviceInfo? = nil, inputDevice: DeviceInfo? = nil
  ) {
    self.sampleRate = sampleRate
    self.bufferFrames = bufferFrames
    self.simulation = simulation
    self.hostClock = hostClock
    self.outputDevice = outputDevice
    self.inputDevice = inputDevice
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
  func open(_ setup: ResolvedSetup, templates: [StimulusTemplate]) async throws -> BackendInfo
  func start() async throws
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
  /// The HAL's own host time for an input sample (`AudioDeviceTranslateTime`), used as a diagnostic
  /// third opinion next to our timeline. Nil when the backend has no such service; the simulator
  /// always returns nil.
  func halHostTime(forInputSample sample: Double) async -> UInt64?
  var events: AsyncStream<DeviceEvent> { get }
  /// Idempotent; the coordinator calls it on every exit path.
  func stop() async
}
