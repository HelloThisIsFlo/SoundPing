import Foundation
import SoundPingKit

/// The default output: one line per hit as it lands, then a speed-test-style summary (D-03).
/// Every method returns a String so the layout is testable; RunCommand prints them.
struct PrettyRenderer {
  var useColor: Bool

  func armedLine(_ info: ArmedInfo) -> String { "" }
  func hitLine(_ record: HitRecord) -> String { "" }
  func summary(_ result: RunResult) -> String { "" }
  func histogram(_ histogram: Histogram?) -> String { "" }
  func sparkline(_ hits: [HitRecord]) -> String { "" }
}
