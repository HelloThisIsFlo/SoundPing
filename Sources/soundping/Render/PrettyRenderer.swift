import Foundation
import SoundPingKit

/// The default output: one line per hit as it lands, then a speed-test-style summary (D-03).
/// Every method returns a String so the layout is testable; RunCommand prints them.
///
/// Rejected hits are never hidden: each prints with its reason (dimmed when color is on) and the
/// summary counts them by reason.
struct PrettyRenderer {
  var useColor: Bool

  private static let sparkBlocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  private static let rejectedMark: Character = "·"
  private static let maxBarColumns = 40

  // MARK: live lines

  /// One level-ramp probe: dimmed, because it is a throwaway and no hit.
  func probeLine(_ probe: ProbeRecord) -> String {
    dim(
      String(
        format: "probe %4.0f dBFS  conf %.2f  peak %6.1f dBFS", probe.levelDbfs, probe.confidence,
        probe.peakDbfs))
  }

  /// The level every hit of the run plays at, and why it is no louder.
  func lockLine(_ lock: LevelLock) -> String {
    String(
      format: "Level locked at %.0f dBFS (%@, ceiling %.0f dBFS)", lock.levelDbfs,
      lock.listenerKind.rawValue, lock.ceilingDbfs)
  }

  /// The ranked input channels of `--in-channel auto`, the winner marked, and how to keep it.
  func channelProbeReport(_ result: ChannelProbeResult) -> String {
    var lines = ["Input channels, best first"]
    for score in result.channels {
      let mark = score.index == result.chosen.index ? "→" : " "
      lines.append(
        String(
          format: "%@ %3d  %@ conf %.2f  at %.0f dBFS", mark, score.index,
          score.name.padded(to: 12), score.confidence, score.levelDbfs))
    }
    let chosen = result.chosen
    lines.append("")
    lines.append(
      String(
        format: "Chosen: channel %d (%@), confidence %.2f, margin %.2f over the runner-up",
        chosen.index, chosen.name, chosen.confidence, chosen.margin))
    if result.saved {
      lines.append("Saved the channel in the setup.")
    } else if let hint = result.saveHint {
      lines.append(hint)
    }
    return lines.joined(separator: "\n")
  }

  /// One line before the first hit: what is about to be measured.
  func armedLine(_ info: ArmedInfo) -> String {
    let setup = info.setup
    let route =
      setup.output.uid == setup.input.uid
      ? setup.output.name : "\(setup.output.name) → \(setup.input.name)"
    let simulated = setup.simulated ? ", simulated" : ""
    let hits = "\(info.parameters.hits) hits after \(info.parameters.warmup) warm-ups"
    return
      "\(info.recipe.id): \(route) (\(Int(setup.sampleRate)) Hz, buffer \(setup.bufferFrames)\(simulated)), \(hits)"
  }

  /// One hit as it lands. A rejected hit shows its reason in place of the numbers.
  func hitLine(_ record: HitRecord) -> String {
    let head = String(format: "#%03d  ", record.index) + record.phase.rawValue.padded(to: 7)
    if let reason = record.rejection {
      return dim("\(head)  rejected: \(reason.rawValue)")
    }
    guard let frames = record.latencyFrames, let ms = record.latencyMs else {
      return "\(head)  no result"
    }
    var line = head + String(format: "  %7.2f frames  %7.3f ms", frames, ms)
    if let confidence = record.confidence { line += String(format: "  conf %.2f", confidence) }
    return line
  }

  // MARK: summary

  /// The whole report printed after the run: summary, histogram and timeline.
  func report(_ result: RunResult) -> String {
    var sections = [summary(result)]
    let bars = histogram(result.histogram)
    if !bars.isEmpty {
      sections.append("Latency histogram (frames)\n" + bars)
    }
    let timeline = sparkline(result.hits)
    if !timeline.isEmpty {
      sections.append("Timeline, one mark per measured hit (· = rejected)\n" + timeline)
    }
    return sections.joined(separator: "\n\n")
  }

  func summary(_ result: RunResult) -> String {
    var lines: [String] = []
    let simulated = result.setup.simulated ? " (simulated)" : ""
    lines.append("Result: \(result.recipe.id)\(simulated)")

    let stats = result.measured.path
    let fired = stats?.n ?? 0
    lines.append("valid \(stats?.valid ?? 0)/\(fired)")

    let rejected = rejectionBreakdown(result.rejectedCounts)
    if !rejected.isEmpty { lines.append("  rejected: \(rejected)") }
    let warmupRejected = result.hits.filter { $0.phase == .warmup && $0.rejection != nil }.count
    if warmupRejected > 0 { lines.append("  warm-ups rejected: \(warmupRejected) (not counted)") }

    var breakdownShown = false
    if let stats, stats.valid > 0 {
      // A same-device run shows three figures and privileges none of them (Phase 1 decision);
      // the per-hit statistics below describe the measured path.
      if let breakdown = roundTripBreakdown(result) {
        lines.append(contentsOf: breakdown)
        breakdownShown = true
      }
      lines.append(
        result.measured.domain == .sample
          ? "Hardware path, per-hit statistics" : "Path (host clock), per-hit statistics")
      lines.append(statLine("median", stats.median))
      lines.append(statLine("jitter", stats.jitter, note: "p5–p95"))
      lines.append(statLine("p95", stats.p95))
      lines.append(statLine("max", stats.max))
    } else {
      lines.append("no valid hits: nothing to report")
    }

    if let warnings = result.preflight?.warnings, !warnings.isEmpty {
      lines.append("Preflight: " + warnings.joined(separator: "; "))
    }
    if let selfTest = result.selfTest { lines.append(selfTestLine(selfTest)) }
    if !breakdownShown { lines.append(contentsOf: reportedVersusMeasured(result)) }

    let path = result.segments.map { Self.shortName(of: $0) }.joined(separator: " → ")
    lines.append("Segments: \(path)")
    lines.append(corrections(result.corrections))
    lines.append("Saved: \(result.runPath)")
    return lines.joined(separator: "\n")
  }

  /// "Clock self-test: PASS (median Δ 0.02, p95 |Δ| 0.05 frames)": does the host clock agree with
  /// the sample clock (CAL-03).
  func selfTestLine(_ selfTest: ClockSelfTestResult) -> String {
    String(
      format: "Clock self-test: %@ (median Δ %.2f, p95 |Δ| %.2f frames)",
      selfTest.pass ? "PASS" : "FAIL", selfTest.medianDeltaFrames, selfTest.p95AbsDeltaFrames)
  }

  /// A same-device round trip as three labelled figures, none of them "the" number: the hardware
  /// path (measured), SoundPing's own buffer part (2 × buffer + both safety offsets) and the total
  /// they add up to. What macOS reports sits beside the figures it can be compared with (RES-02);
  /// it is information only and never applied. Nil when the run has no same-device figures.
  func roundTripBreakdown(_ result: RunResult) -> [String]? {
    let measured = result.measured
    guard measured.domain == .sample, let path = measured.path?.median,
      let buffer = measured.ioOffset?.median, let total = measured.appRoundTrip?.median
    else { return nil }
    let reported = result.reported
    let rate = result.setup.sampleRate

    func row(_ label: String, _ value: StatValue, _ note: String) -> String {
      "  " + label.padded(to: 17)
        + String(format: "%8.2f frames %8.3f ms", value.frames, value.ms) + "  " + note
    }
    func macOSReports(_ frames: Int) -> String {
      let ms = rate > 0 ? Double(frames) / rate * 1000 : 0
      return String(format: "; macOS reports %.2f frames, %.3f ms", Double(frames), ms)
    }

    var bufferNote = "Δio read from the stamps"
    if let reported {
      let out = reported.output
      let inp = reported.input
      let buffers =
        out.bufferFrames == inp.bufferFrames
        ? "2 × \(out.bufferFrames) buffer" : "\(out.bufferFrames) + \(inp.bufferFrames) buffer"
      let formula =
        "\(buffers) + \(inp.safetyOffsetFrames) safety in + \(out.safetyOffsetFrames) safety out"
      bufferNote =
        abs(buffer.frames - Double(reported.expectedIoOffsetFrames)) <= 0.5
        ? "calculated: \(formula)"
        : String(
          format: "read from the stamps; %@ gives %d", formula, reported.expectedIoOffsetFrames)
    }

    return [
      "Round trip at buffer \(result.setup.bufferFrames), \(Int(rate)) Hz",
      row("hardware path", path, "measured" + (reported.map { macOSReports($0.pathFrames) } ?? "")),
      row("SoundPing buffer", buffer, bufferNote),
      row(
        "total", total,
        "path + buffer" + (reported.map { macOSReports($0.appRoundTripFrames) } ?? "")),
    ]
  }

  /// What macOS says next to what was heard, so a mismatch shows which segment is off (RES-02).
  /// The reported figures are information only: nothing here is subtracted from a measurement.
  func reportedVersusMeasured(_ result: RunResult) -> [String] {
    guard let reported = result.reported else { return [] }
    let measured = result.measured
    let rate = reported.sampleRate

    func row(_ label: String, _ word: String, frames: Double, measured: StatValue?) -> String {
      let ms = rate > 0 ? frames / rate * 1000 : 0
      var line =
        "  " + label.padded(to: 15)
        + String(format: "%@ %7.2f frames %8.3f ms", word.padded(to: 8), frames, ms)
      if let measured {
        line += String(format: "   measured %7.2f frames %8.3f ms", measured.frames, measured.ms)
      } else {
        line += "   measured -"
      }
      return line
    }

    var lines = ["Reported vs measured"]
    switch measured.domain {
    case .sample:
      lines.append(
        row(
          "path", "reported", frames: Double(reported.pathFrames), measured: measured.path?.median))
      lines.append(
        row(
          "app round trip", "reported", frames: Double(reported.appRoundTripFrames),
          measured: measured.appRoundTrip?.median))
      lines.append(
        row(
          "Δio per buffer", "expected", frames: Double(reported.expectedIoOffsetFrames),
          measured: measured.ioOffset?.median))
      lines.append("  (expected Δio = both buffers + both safety offsets)")
    case .host:
      lines.append(
        row(
          "path (host)", "reported", frames: Double(reported.pathFrames),
          measured: measured.path?.median))
      lines.append("  (app round trip and Δio are defined for a single device only)")
    }
    return lines
  }

  private func statLine(_ label: String, _ value: StatValue?, note: String? = nil) -> String {
    guard let value else { return "\(label.padded(to: 7)) -" }
    var line =
      label.padded(to: 7) + String(format: "%8.3f ms  %8.2f frames", value.ms, value.frames)
    if let note { line += "  (\(note))" }
    return line
  }

  private func rejectionBreakdown(_ counts: [String: Int]) -> String {
    // The reasons the engine knows, in declaration order, then anything a newer engine added.
    let known = RejectionReason.allCases.map(\.rawValue)
    let order = known + counts.keys.filter { !known.contains($0) }.sorted()
    return order.compactMap { key in
      guard let count = counts[key], count > 0 else { return nil }
      return "\(key) \(count)"
    }.joined(separator: ", ")
  }

  private func corrections(_ corrections: [Correction]) -> String {
    guard !corrections.isEmpty else { return "Corrections: none (raw measurement)" }
    let items = corrections.map {
      String(format: "%@ %.3f ms (%@)", $0.name, $0.valueMs, $0.source.rawValue)
    }
    return "Corrections: " + items.joined(separator: ", ")
  }

  /// "Audio output (driver, ...)" and "Cable or air between ..." are too long for one line.
  private static func shortName(of segment: Segment) -> String {
    switch segment.id {
    case "audioOutput": return "Audio output"
    case "transmission": return "Cable or air"
    case "audioInput": return "Audio input"
    default: return segment.name
    }
  }

  // MARK: histogram and sparkline

  /// One row per bin: its frame range, a bar of █ proportional to the count (longest bar 40
  /// columns), and the count. Empty when there is nothing to bin.
  func histogram(_ histogram: Histogram?) -> String {
    guard let histogram, let largest = histogram.counts.max(), largest > 0 else { return "" }
    return histogram.counts.enumerated().map { bin, count in
      let low = histogram.firstBinStartFrames + Double(bin) * histogram.binWidthFrames
      let high = histogram.firstBinStartFrames + Double(bin + 1) * histogram.binWidthFrames
      let columns =
        count == 0
        ? 0 : max(1, Int((Double(count) / Double(largest) * Double(Self.maxBarColumns)).rounded()))
      let bar = String(repeating: "█", count: columns)
      return String(format: "%8.2f – %8.2f │", low, high) + bar + " \(count)"
    }.joined(separator: "\n")
  }

  /// One character per measured hit in hit order, ▁ to █ between the lowest and highest latency;
  /// · for a rejected hit. Warm-ups and probes are not drawn.
  func sparkline(_ hits: [HitRecord]) -> String {
    let measured = hits.filter { $0.phase == .measure }
    let values = measured.compactMap { $0.rejection == nil ? $0.latencyFrames : nil }
    guard let low = values.min(), let high = values.max() else {
      return String(repeating: Self.rejectedMark, count: measured.count)
    }
    let top = Double(Self.sparkBlocks.count - 1)
    return String(
      measured.map { record -> Character in
        guard record.rejection == nil, let frames = record.latencyFrames else {
          return Self.rejectedMark
        }
        guard high > low else { return Self.sparkBlocks[Self.sparkBlocks.count / 2] }
        return Self.sparkBlocks[Int(((frames - low) / (high - low) * top).rounded())]
      })
  }

  // MARK: color

  private func dim(_ text: String) -> String {
    useColor ? "\u{1B}[2m\(text)\u{1B}[0m" : text
  }
}

extension String {
  fileprivate func padded(to width: Int) -> String {
    count >= width ? self : self + String(repeating: " ", count: width - count)
  }
}
