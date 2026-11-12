/// The one error type the engine and CLI speak. Agents branch on `kind` and `code`, never on prose (D-01, D-03).
public struct SoundPingError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
  public enum Kind: String, Codable, Sendable {
    case usage
    case preflight
    case deviceChanged
    case gate
    case busy
    case internalError = "internal"
  }

  public var kind: Kind
  public var code: String
  public var detail: String
  public var context: [String: String]

  public init(kind: Kind, code: String, detail: String, context: [String: String] = [:]) {
    self.kind = kind
    self.code = code
    self.detail = detail
    self.context = context
  }

  public static func usage(_ code: String, _ detail: String, context: [String: String] = [:])
    -> SoundPingError
  {
    SoundPingError(kind: .usage, code: code, detail: detail, context: context)
  }

  /// A check before the run failed (exit 65).
  public static func preflight(_ code: String, _ detail: String, context: [String: String] = [:])
    -> SoundPingError
  {
    SoundPingError(kind: .preflight, code: code, detail: detail, context: context)
  }

  public static func deviceChanged(
    _ code: String, _ detail: String, context: [String: String] = [:]
  ) -> SoundPingError {
    SoundPingError(kind: .deviceChanged, code: code, detail: detail, context: context)
  }

  public static func internalFailure(
    _ code: String, _ detail: String, context: [String: String] = [:]
  ) -> SoundPingError {
    SoundPingError(kind: .internalError, code: code, detail: detail, context: context)
  }

  public var description: String { "\(code): \(detail)" }
}

extension SoundPingError {
  /// The error a device event stands for when it ends a run or a probe (ENG-07). An overload is
  /// not one: the callers handle it by rejecting the hits it touched.
  static func forDeviceEvent(_ event: DeviceEvent) -> SoundPingError {
    switch event {
    case .gone(let uid):
      return .deviceChanged(
        "deviceGone", "device '\(uid)' disappeared during the run", context: ["uid": uid])
    case .sampleRateChanged(let uid, let from, let to):
      return .deviceChanged(
        "sampleRateChanged", "device '\(uid)' changed sample rate from \(from) to \(to) Hz",
        context: ["uid": uid, "from": String(from), "to": String(to)])
    case .bufferSizeChanged(let uid, let from, let to):
      return .deviceChanged(
        "bufferSizeChanged", "device '\(uid)' changed buffer size from \(from) to \(to) frames",
        context: ["uid": uid, "from": String(from), "to": String(to)])
    case .streamConfigChanged(let uid):
      return .deviceChanged(
        "streamConfigChanged", "device '\(uid)' changed its stream configuration",
        context: ["uid": uid])
    case .ioStopped(let uid):
      return .deviceChanged(
        "ioStopped", "device '\(uid)' stopped unexpectedly", context: ["uid": uid])
    case .overload(let uid, _):
      return .internalFailure("unexpectedOverload", "overload on '\(uid)' is not an abort")
    }
  }
}
