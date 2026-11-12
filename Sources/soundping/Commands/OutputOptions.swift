import ArgumentParser

/// How a command reports its result (D-03).
struct OutputOptions: ParsableArguments {
  @Flag(help: "Print the final result as one JSON object, byte-identical to run.json.")
  var json = false
}
