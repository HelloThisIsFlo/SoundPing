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

  private struct Defaults: Encodable {
    var hits: Int
    var warmup: Int
    var spacingMinMs: Double
    var spacingMaxMs: Double
    var maxLatencyMs: Double
    var templateId: String
    /// Where the level ramp starts when `--level` is not given (the engine's real first probe).
    var rampStartLevelDbfs: Double
    var minValidFraction: Double
  }

  private struct Entry: Encodable {
    var id: String
    var version: Int
    var title: String
    var summary: String
    var segments: [Segment]
    var defaults: Defaults
  }

  private struct Envelope: Encodable {
    var schemaVersion = 1
    var recipes: [Entry]
  }

  func run() async throws {
    try await withErrorReporting(jsonMode: json) {
      let entries = RecipeRegistry.all.map { recipe -> Entry in
        // The seed is per run, so it is not part of a recipe's defaults.
        let parameters = recipe.defaultParameters(seed: 0)
        return Entry(
          id: recipe.id, version: recipe.version, title: recipe.title, summary: recipe.summary,
          segments: recipe.segments,
          defaults: Defaults(
            hits: parameters.hits, warmup: parameters.warmup,
            spacingMinMs: parameters.spacingMinMs, spacingMaxMs: parameters.spacingMaxMs,
            maxLatencyMs: parameters.maxLatencyMs, templateId: parameters.templateId,
            rampStartLevelDbfs: LevelRamp.firstProbeDbfs, minValidFraction: parameters.minValidFraction))
      }
      if json {
        try writeJSONLine(Envelope(recipes: entries))
      } else {
        for entry in entries {
          print("\(entry.id)  \(entry.title)")
          print("  \(entry.summary)")
          print("  segments: \(entry.segments.map(\.id).joined(separator: " -> "))")
          print(
            "  defaults: \(entry.defaults.hits) hits, \(entry.defaults.warmup) warm-ups, spacing \(Int(entry.defaults.spacingMinMs))-\(Int(entry.defaults.spacingMaxMs)) ms, level ramp starts at \(Int(entry.defaults.rampStartLevelDbfs)) dBFS"
          )
        }
      }
    }
  }
}
