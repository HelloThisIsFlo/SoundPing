import ArgumentParser
import Foundation
import SoundPingKit

/// `soundping recipes` (D-02): what can be run, so an agent never has to guess a recipe id.
struct RecipesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "recipes",
    abstract: "List the available recipes with their segments and defaults."
  )

  @Flag(help: "Print the listing as one JSON object.")
  var json = false

  struct Defaults: Encodable {
    var hits: Int
    var warmup: Int
    var spacingMinMs: Double
    var spacingMaxMs: Double
    var maxLatencyMs: Double
    /// A run's chirp band follows the listener unless `--template` names one, so there is no one
    /// default template: the key is always `null` and `templateRule` says what is used instead.
    var templateId: String? = nil
    var templateRule: String
    /// Where the level ramp starts when `--level` is not given (the engine's real first probe).
    var rampStartLevelDbfs: Double
    var minValidFraction: Double

    private enum CodingKeys: String, CodingKey {
      case hits, warmup, spacingMinMs, spacingMaxMs, maxLatencyMs, templateId, templateRule
      case rampStartLevelDbfs, minValidFraction
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(hits, forKey: .hits)
      try container.encode(warmup, forKey: .warmup)
      try container.encode(spacingMinMs, forKey: .spacingMinMs)
      try container.encode(spacingMaxMs, forKey: .spacingMaxMs)
      try container.encode(maxLatencyMs, forKey: .maxLatencyMs)
      if let templateId {
        try container.encode(templateId, forKey: .templateId)
      } else {
        try container.encodeNil(forKey: .templateId)
      }
      try container.encode(templateRule, forKey: .templateRule)
      try container.encode(rampStartLevelDbfs, forKey: .rampStartLevelDbfs)
      try container.encode(minValidFraction, forKey: .minValidFraction)
    }
  }

  struct Entry: Encodable {
    var id: String
    var version: Int
    var title: String
    var summary: String
    var segments: [Segment]
    var defaults: Defaults
  }

  /// schemaVersion 2: `defaults.templateId` is `null` with a `templateRule`, and the ramp start
  /// key is `rampStartLevelDbfs` (version 1 advertised a start level and a template the engine
  /// never used).
  struct Envelope: Encodable {
    var schemaVersion = 2
    var recipes: [Entry]
  }

  static func envelope() -> Envelope {
    Envelope(
      recipes: RecipeRegistry.all.map { recipe -> Entry in
        // The seed is per run, so it is not part of a recipe's defaults.
        let parameters = recipe.defaultParameters(seed: 0)
        return Entry(
          id: recipe.id, version: recipe.version, title: recipe.title, summary: recipe.summary,
          segments: recipe.segments,
          defaults: Defaults(
            hits: parameters.hits, warmup: parameters.warmup,
            spacingMinMs: parameters.spacingMinMs, spacingMaxMs: parameters.spacingMaxMs,
            maxLatencyMs: parameters.maxLatencyMs, templateRule: LevelRamp.templateRule,
            rampStartLevelDbfs: LevelRamp.firstProbeDbfs,
            minValidFraction: parameters.minValidFraction))
      })
  }

  func run() async throws {
    try await withErrorReporting(jsonMode: json) {
      let envelope = Self.envelope()
      if json {
        try writeJSONLine(envelope)
      } else {
        for entry in envelope.recipes {
          print("\(entry.id)  \(entry.title)")
          print("  \(entry.summary)")
          print("  segments: \(entry.segments.map(\.id).joined(separator: " -> "))")
          print(
            "  defaults: \(entry.defaults.hits) hits, \(entry.defaults.warmup) warm-ups, spacing \(Int(entry.defaults.spacingMinMs))-\(Int(entry.defaults.spacingMaxMs)) ms, level ramp starts at \(Int(entry.defaults.rampStartLevelDbfs)) dBFS, template \(entry.defaults.templateRule)"
          )
        }
      }
    }
  }
}
