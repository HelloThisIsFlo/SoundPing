import Testing

@testable import SoundPingKit

@Suite struct ReportedLatencyTests {
  private func fixture(_ uid: String) throws -> DeviceInfo {
    try #require(try SimulatedCatalog().listing().audio.first { $0.uid == uid })
  }

  @Test func theScarlettAtBuffer128ReportsAFiftySevenFramePath() throws {
    let scarlett = try fixture(SimulatedCatalog.scarlettUID)
    let reported = ReportedLatency.compute(
      output: scarlett, outChannels: [1, 2], input: scarlett, inChannel: 7, outputBufferFrames: 128,
      inputBufferFrames: 128, sampleRate: 48_000)
    #expect(reported.pathFrames == 57)
    #expect(abs(reported.pathMs - 1.1875) < 1e-9)
    #expect(reported.source == "halReported")
  }

  @Test func theScarlettAppRoundTripAddsBothSafetyOffsetsAndBothBuffers() throws {
    let scarlett = try fixture(SimulatedCatalog.scarlettUID)
    let reported = ReportedLatency.compute(
      output: scarlett, outChannels: [1, 2], input: scarlett, inChannel: 7, outputBufferFrames: 128,
      inputBufferFrames: 128, sampleRate: 48_000)
    #expect(reported.appRoundTripFrames == 341)
    #expect(reported.expectedIoOffsetFrames == 284)
    #expect(reported.output.safetyOffsetFrames == 14)
    #expect(reported.input.safetyOffsetFrames == 14)
    #expect(reported.output.bufferFrames == 128 && reported.input.bufferFrames == 128)
  }

  @Test func theMacBookSpeakersToMicrophoneKeepsTheStreamLatency() throws {
    let reported = ReportedLatency.compute(
      output: try fixture(SimulatedCatalog.macSpeakersUID), outChannels: [1, 2],
      input: try fixture(SimulatedCatalog.macMicrophoneUID), inChannel: 1, outputBufferFrames: 512,
      inputBufferFrames: 512, sampleRate: 48_000)
    #expect(reported.pathFrames == 2203)
    #expect(reported.output.streamLatencyFrames == 690)
    #expect(reported.input.streamLatencyFrames == 1439)
    #expect(reported.appRoundTripFrames == 2203 + 48 + 36 + 1024)
  }

  private func twoStreamDevice() -> DeviceInfo {
    let channels = (1...4).map {
      ChannelInfo(
        index: $0, name: "In \($0)", streamIndex: $0 <= 2 ? 0 : 1,
        channelInStream: $0 <= 2 ? $0 : $0 - 2)
    }
    let scope = ScopeInfo(
      channels: channels, deviceLatency: 5, streamLatencies: [10, 500], safetyOffset: 0,
      bufferFrameSize: 128, bufferFrameSizeRange: FrameSizeRange(min: 15, max: 4096))
    return DeviceInfo(
      uid: "two-streams", name: "Two Streams", transport: "usb", nominalSampleRate: 48_000,
      input: scope, output: scope)
  }

  @Test func theInputStreamHoldingTheChosenChannelSetsItsLatency() throws {
    let device = twoStreamDevice()
    let first = ReportedLatency.compute(
      output: device, outChannels: [1], input: device, inChannel: 1, outputBufferFrames: 128,
      inputBufferFrames: 128, sampleRate: 48_000)
    let second = ReportedLatency.compute(
      output: device, outChannels: [1], input: device, inChannel: 3, outputBufferFrames: 128,
      inputBufferFrames: 128, sampleRate: 48_000)
    #expect(first.input.streamLatencyFrames == 10)
    #expect(second.input.streamLatencyFrames == 500)
  }

  @Test func outputChannelsInDifferentStreamsReportTheSlowerStream() throws {
    let device = twoStreamDevice()
    let reported = ReportedLatency.compute(
      output: device, outChannels: [2, 3], input: device, inChannel: 1, outputBufferFrames: 128,
      inputBufferFrames: 128, sampleRate: 48_000)
    #expect(reported.output.streamLatencyFrames == 500)
  }

  @Test func aDeviceWithoutTheDirectionContributesNothing() throws {
    let speakers = try fixture(SimulatedCatalog.macSpeakersUID)
    let reported = ReportedLatency.compute(
      output: speakers, outChannels: [1, 2], input: speakers, inChannel: 1, outputBufferFrames: 128,
      inputBufferFrames: 128, sampleRate: 48_000)
    #expect(reported.input.deviceLatencyFrames == 0)
    #expect(reported.input.streamLatencyFrames == 0)
    #expect(reported.pathFrames == 750)
  }

  @Test func eachDirectionUsesItsOwnBufferWhenTheTwoDevicesDiffer() throws {
    let speakers = try fixture(SimulatedCatalog.macSpeakersUID)
    let microphone = try fixture(SimulatedCatalog.macMicrophoneUID)
    let same = ReportedLatency.compute(
      output: speakers, outChannels: [1, 2], input: microphone, inChannel: 1,
      outputBufferFrames: 128, inputBufferFrames: 128, sampleRate: 48_000)
    let split = ReportedLatency.compute(
      output: speakers, outChannels: [1, 2], input: microphone, inChannel: 1,
      outputBufferFrames: 512, inputBufferFrames: 128, sampleRate: 48_000)
    #expect(split.output.bufferFrames == 512 && split.input.bufferFrames == 128)
    // Only the output's buffer grew, so only its 384 frames are added.
    #expect(split.expectedIoOffsetFrames == same.expectedIoOffsetFrames + 384)
    #expect(split.appRoundTripFrames == same.appRoundTripFrames + 384)
    #expect(split.pathFrames == same.pathFrames)
  }
}
