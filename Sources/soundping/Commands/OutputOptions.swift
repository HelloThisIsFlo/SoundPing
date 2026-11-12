import ArgumentParser

/// How a command reports its result (D-03).
struct OutputOptions: ParsableArguments {
  @Flag(help: "Print the final result as one JSON object, byte-identical to run.json.")
  var json = false

  @Flag(help: "Stream every event as one JSON object per line while the run happens.")
  var ndjson = false

  /// Either data mode: stdout carries data only, everything else goes to stderr.
  var isDataMode: Bool { json || ndjson }

  mutating func validate() throws {
    if json && ndjson {
      throw ValidationError("--json and --ndjson cannot be used together; pick one.")
    }
  }
}
