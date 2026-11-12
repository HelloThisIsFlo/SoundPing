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
