import ArgumentParser
import SoundPingKit

@main
struct SoundPing: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "soundping",
    abstract: "Measure where the latency in your music setup comes from.",
    version: SoundPingInfo.version,
    subcommands: [
      RunCommand.self, RunsCommand.self, DevicesCommand.self, RecipesCommand.self,
      PathsCommand.self, SelftestCommand.self,
    ]
  )
}
