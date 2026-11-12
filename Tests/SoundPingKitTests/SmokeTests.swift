import Testing

@testable import SoundPingKit

@Suite struct SmokeTests {
  @Test func versionLooksLikeSemver() {
    #expect(SoundPingInfo.version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
  }
}
