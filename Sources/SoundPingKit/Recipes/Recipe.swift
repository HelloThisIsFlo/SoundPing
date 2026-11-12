/// A named test: what to fire, how often, and which segments of the chain the number covers.
public struct Recipe: Sendable, Equatable {
  public let id: String
  public let version: Int
  public let title: String
  public let summary: String
  /// Segments in signal-flow order (ENG-06). Listed separately, never merged.
  public let segments: [Segment]

  public init(
    id: String, version: Int, title: String, summary: String, segments: [Segment]
  ) {
    self.id = id
    self.version = version
    self.title = title
    self.summary = summary
    self.segments = segments
  }

  /// The recipe defaults (D-04): 100 measured hits, 5 warm-ups.
  public func defaultParameters(seed: UInt64) -> RunParameters {
    RunParameters(seed: seed)
  }

  public var ref: RecipeRef { RecipeRef(id: id, version: version) }
}

public enum RecipeRegistry {
  public static let roundTrip = Recipe(
    id: "round-trip",
    version: 1,
    title: "Audio round trip",
    summary:
      "Plays a chirp out of the output device and listens on the input device, then measures the delay.",
    segments: [
      Segment(id: "audioOutput", name: "Audio output (driver, converter, output device)"),
      Segment(id: "transmission", name: "Cable or air between output and input"),
      Segment(id: "audioInput", name: "Audio input (input device, converter, driver)"),
    ]
  )

  public static let all: [Recipe] = [roundTrip]

  public static func recipe(id: String) throws -> Recipe {
    guard let recipe = all.first(where: { $0.id == id }) else {
      throw SoundPingError.usage(
        "unknownRecipe",
        "no recipe named '\(id)'; available: \(all.map(\.id).joined(separator: ", "))",
        context: ["recipe": id]
      )
    }
    return recipe
  }
}
