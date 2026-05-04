/// SpeedTestView.swift — On-demand network speed test panel
///
/// Shows the latest speed test results and a 20-point history chart.
/// Runs Apple's built-in networkQuality tool (macOS 12+, no external deps).
///
/// Layout:
///   Top row    — DL / UL / Latency / Responsiveness tiles
///   Middle     — "Run Test" button with live progress + quality badge
///   History    — Dual-line sparkline chart (DL in blue, UL in green)
///   History list — Recent results table

import SwiftUI

struct SpeedTestView: View {
    @EnvironmentObject var speedTestMonitor: SpeedTestMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                resultTiles
                runButton
                if !speedTestMonitor.history.isEmpty {
                    historyChart
                    historyTable
                }
                ClaudeCompanionCard(
                    context: speedTestClaudeContext(),
                    promptHint: speedTestClaudeHint()
                )
                Spacer(minLength: 40)
            }
            .padding(20)
        }
    }

    // MARK: - Result tiles

    private var resultTiles: some View {
        let r = speedTestMonitor.lastResult
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: 4),
            spacing: 12
        ) {
            SpeedTile(
                label:    "Download",
                value:    r.map { String(format: "%.0f", $0.downloadMbps) } ?? "–",
                unit:     "Mbps",
                color:    tileColor(r?.downloadMbps, threshold: nil),
                icon:     "arrow.down.circle.fill"
            )
            SpeedTile(
                label:    "Upload",
                value:    r.map { String(format: "%.0f", $0.uploadMbps) } ?? "–",
                unit:     "Mbps",
                color:    .green,
                icon:     "arrow.up.circle.fill"
            )
            SpeedTile(
                label:    "Latency",
                value:    r.map { String(format: "%.0f", $0.latencyMs) } ?? "–",
                unit:     "ms",
                color:    latencyColor(r?.latencyMs),
                icon:     "clock.fill"
            )
            SpeedTile(
                label:    "Responsiveness",
                value:    r.map { "\($0.responsiveness)" } ?? "–",
                unit:     "RPM",
                color:    responsivenessColor(r?.responsiveness),
                icon:     "waveform.path.ecg"
            )
        }
    }

    private func speedTestClaudeContext() -> String {
        var lines = ["## NetWatch Speed Test Results"]
        if let r = speedTestMonitor.lastResult {
            if r.isSuccess {
                lines.append(String(format: "Download: %.1f Mbps | Upload: %.1f Mbps", r.downloadMbps, r.uploadMbps))
                lines.append(String(format: "Latency: %.0f ms | Base RTT: %.0f ms | Responsiveness: %d RPM", r.latencyMs, r.baseRttMs, r.responsiveness))
                lines.append("Quality: \(r.quality.label) | Responsiveness: \(r.responsivenessLabel)")
                lines.append("DL flows: \(r.downloadFlows) | UL flows: \(r.uploadFlows)")
                lines.append("Tested: \(r.timestamp.formatted(date: .abbreviated, time: .shortened))")
            } else {
                lines.append("Last test FAILED: \(r.error ?? "unknown error")")
            }
        } else {
            lines.append("No speed test results yet.")
        }
        if let dl = speedTestMonitor.avgDownloadMbps, let ul = speedTestMonitor.avgUploadMbps {
            lines.append(String(format: "10-test avg: %.1f Mbps ↓ · %.1f Mbps ↑", dl, ul))
        }
        let successfulHistory = speedTestMonitor.history.filter(\.isSuccess)
        if !successfulHistory.isEmpty {
            lines.append("History (\(successfulHistory.count) tests stored):")
            for r in successfulHistory.prefix(5) {
                lines.append(String(format: "  \(r.timestamp.formatted(date: .omitted, time: .shortened)): %.1f↓ / %.1f↑ Mbps, %.0f ms", r.downloadMbps, r.uploadMbps, r.latencyMs))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func speedTestClaudeHint() -> String {
        guard let r = speedTestMonitor.lastResult, r.isSuccess else {
            return "My speed test failed. What could cause networkQuality to fail and how do I troubleshoot it?"
        }
        if r.downloadMbps < 50 {
            return String(format: "My download is only %.1f Mbps. Is that normal for my plan and what could be limiting it?", r.downloadMbps)
        }
        if r.latencyMs > 80 {
            return String(format: "Download is fine but latency is %.0f ms. Why is latency high even with decent throughput?", r.latencyMs)
        }
        return String(format: "Speed test: %.1f↓ / %.1f↑ Mbps, %.0f ms. Is this what I should expect, and are there any red flags?", r.downloadMbps, r.uploadMbps, r.latencyMs)
    }

    private func tileColor(_ val: Double?, threshold: Double?) -> Color {
        guard let v = val else { return .secondary }
        if let t = threshold, v < t { return .red }
        if v >= 100 { return .green }
        if v >= 25  { return .blue }
        if v >= 5   { return .yellow }
        return .red
    }

    private func latencyColor(_ ms: Double?) -> Color {
        guard let ms else { return .secondary }
        if ms < 30  { return .green }
        if ms < 80  { return .blue }
        if ms < 150 { return .yellow }
        return .red
    }

    private func responsivenessColor(_ rpm: Int?) -> Color {
        guard let rpm else { return .secondary }
        if rpm >= 200 { return .green }
        if rpm >= 100 { return .yellow }
        return .red
    }

    // MARK: - Run button

    private var runButton: some View {
        GroupBox {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if speedTestMonitor.isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(speedTestMonitor.progress.isEmpty ? "Running speed test…" : speedTestMonitor.progress)
                                .font(.callout)
                        }
                        Text("This takes 60–90 seconds in sequential mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let r = speedTestMonitor.lastResult {
                        if r.isSuccess {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Last test: \(r.timestamp, style: .relative) ago · \(r.quality.label)")
                                    .font(.callout)
                            }
                            if let dl = speedTestMonitor.avgDownloadMbps,
                               let ul = speedTestMonitor.avgUploadMbps {
                                Text(String(format: "10-test avg: %.0f Mbps ↓ · %.0f Mbps ↑", dl, ul))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text(r.error ?? "Test failed")
                                    .font(.callout)
                                    .foregroundStyle(.red)
                            }
                        }
                    } else {
                        Text("No speed test results yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Results are stored across app restarts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if speedTestMonitor.isRunning {
                    Button("Cancel") {
                        speedTestMonitor.cancelTest()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        speedTestMonitor.runTest()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "speedometer")
                            Text("Run Speed Test")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Runs Apple networkQuality in sequential mode — takes 60–90 seconds")
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - History chart

    private var historyChart: some View {
        GroupBox("Speed History (last \(speedTestMonitor.history.filter(\.isSuccess).prefix(20).count) tests)") {
            VStack(alignment: .leading, spacing: 8) {
                // Dual-line chart
                SpeedHistoryChart(
                    downloadValues: speedTestMonitor.recentDownloadMbps,
                    uploadValues:   speedTestMonitor.recentUploadMbps
                )
                .frame(height: 80)

                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Rectangle().fill(Color.blue).frame(width: 12, height: 3)
                        Text("Download").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Rectangle().fill(Color.green).frame(width: 12, height: 3)
                        Text("Upload").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let dl = speedTestMonitor.avgDownloadMbps {
                        Text(String(format: "avg ↓ %.0f Mbps", dl))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let ul = speedTestMonitor.avgUploadMbps {
                        Text(String(format: "avg ↑ %.0f Mbps", ul))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - History table

    private var historyTable: some View {
        GroupBox("Recent Tests") {
            VStack(spacing: 0) {
                // Column headers
                HStack(spacing: 0) {
                    Text("Time")         .frame(width: 120, alignment: .leading)
                    Text("Download")     .frame(width: 80, alignment: .trailing)
                    Text("Upload")       .frame(width: 80, alignment: .trailing)
                    Text("Latency")      .frame(width: 70, alignment: .trailing)
                    Text("RPM")          .frame(width: 60, alignment: .trailing)
                    Text("Quality")      .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()

                ForEach(speedTestMonitor.history.prefix(15)) { result in
                    SpeedHistoryRow(result: result)
                    Divider().padding(.horizontal, 8)
                }
            }
        }
    }
}

// MARK: - Speed Tile

private struct SpeedTile: View {
    let label: String
    let value: String
    let unit:  String
    let color: Color
    let icon:  String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title2, design: .rounded).bold())
                .foregroundStyle(color)
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        )
    }
}

// MARK: - History Chart

private struct SpeedHistoryChart: View {
    let downloadValues: [Double]
    let uploadValues:   [Double]

    var body: some View {
        GeometryReader { geo in
            let all   = downloadValues + uploadValues
            let maxV  = (all.max() ?? 1) * 1.1
            let minV  = 0.0
            let range = max(1, maxV - minV)
            let w     = geo.size.width
            let h     = geo.size.height

            ZStack {
                // Grid lines
                ForEach([0.25, 0.5, 0.75], id: \.self) { fraction in
                    Path { p in
                        let y = h * (1 - fraction)
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5)
                }

                // Download line
                if downloadValues.count >= 1 {
                    speedLine(values: downloadValues, color: .blue, geo: geo, range: range, minV: minV)
                }

                // Upload line
                if uploadValues.count >= 1 {
                    speedLine(values: uploadValues, color: .green, geo: geo, range: range, minV: minV)
                }
            }
        }
    }

    private func speedLine(values: [Double], color: Color, geo: GeometryProxy,
                           range: Double, minV: Double) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        let n = values.count

        return Path { path in
            if n == 1 {
                // Single point — 2px segment with round cap renders as a visible dot
                let x = w / 2
                let y = h * (1.0 - CGFloat((values[0] - minV) / range))
                path.move(to: CGPoint(x: x - 1, y: y))
                path.addLine(to: CGPoint(x: x + 1, y: y))
                return
            }
            for (i, v) in values.enumerated() {
                let x = w * CGFloat(i) / CGFloat(max(1, n - 1))
                let y = h * (1.0 - CGFloat((v - minV) / range))
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else       { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - History Row

private struct SpeedHistoryRow: View {
    let result: SpeedTestResult

    var body: some View {
        HStack(spacing: 0) {
            Text(result.timestamp, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            if result.isSuccess {
                Text(String(format: "%.0f Mbps", result.downloadMbps))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.blue)
                    .frame(width: 80, alignment: .trailing)
                Text(String(format: "%.0f Mbps", result.uploadMbps))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(width: 80, alignment: .trailing)
                Text(String(format: "%.0f ms", result.latencyMs))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                Text("\(result.responsiveness)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text(result.quality.label)
                    .font(.caption2)
                    .foregroundStyle(qualityColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(qualityColor.opacity(0.12)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
            } else {
                Text(result.error ?? "Failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var qualityColor: Color {
        switch result.quality {
        case .excellent: return .green
        case .good:      return .blue
        case .fair:      return .yellow
        case .poor, .error: return .red
        }
    }
}
