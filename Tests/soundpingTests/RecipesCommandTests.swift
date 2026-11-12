import Foundation
import Testing

@testable import SoundPingKit
@testable import soundping

/// `soundping recipes --json` must advertise what a run really uses (WR-09, IN-14).
@Suite struct RecipesCommandTests {
  private static func json() throws -> [String: Any] {
    let data = try RunJSON.fileEncoder().encode(RecipesCommand.envelope())
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func theEnvelopeIsSchemaTwoAndNamesTheTemplateRuleInsteadOfAFalseDefault() throws {
    let envelope = try Self.json()
    #expect(envelope["schemaVersion"] as? Int == 2)
    let recipes = try #require(envelope["recipes"] as? [[String: Any]])
    let defaults = try #require(recipes.first?["defaults"] as? [String: Any])

    #expect(defaults.keys.contains("templateId"), "the key is there, explicitly null")
    #expect(defaults["templateId"] is NSNull)
    let rule = try #require(defaults["templateRule"] as? String)
    #expect(rule.contains("chirp-loopback") && rule.contains("chirp-speaker"))
    #expect(defaults["rampStartLevelDbfs"] as? Double == LevelRamp.firstProbeDbfs)
    #expect(defaults["startLevelDbfs"] == nil)
  }
}
