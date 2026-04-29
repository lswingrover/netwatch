import SwiftUI

/// Uptime swimlane — shows each ping target as a horizontal row of colored
/// segments over the last ~15 minutes of collected results.
struct TimelineView: View {
    @EnvironmentObject var monitor: NetworkMonitorService

    private let windowSeconds: Double = 900   // 15 minutes
    private let rowHeight: CGFloat    = 22
    private let labelWidth: CGFloat   = 160

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Legend + time axis label
                HStack {
                    Spacer().frame(width: labelWidth)
                    Text("← 15 minutes ago")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("Now →")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)

                // One row per ping target
                ForEach(monitor.pingStates) { state in
                    UptimeRow(state: state,
                              windowSeconds: windowSeconds,
                              rowHeight: rowHeight,
                              labelWidth: labelWidth)
                }

                // DNS targets
                if !monitor.dnsStates.isEmpty {
                    Divider().padding(.horizontal, 20)

                    ForEach(monitor.dnsStates) { state in
                        DNSUptimeRow(state: state,
                                     windowSeconds: windowSeconds,
                                     rowHeight: rowHeight,
                                     labelWidth: labelWidth)
                    }
                }

                // Summary legend
                HStack(spacing: 16) {
                    legendDot(.green,  "Success")
                    legendDot(.red,    "Failure")
                    legendDot(Color(white: 0.3), "No data")
                }
                .font(.caption)
                .padding(.horizontal, 20)
                .padding(.top, 4)

                Spacer(minLength: 20)
            }
            .padding(.vertical, 20)
        }
    }

    @ViewBuilder
    func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 16, height: 10)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Ping uptime row

private struct UptimeRow: View {
    @ObservedObject var state: PingState
    let windowSeconds: Double
    let rowHeight: CGFloat
    let labelWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Text(state.target.displayName)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .trailing)

            GeometryReader { geo in
                UptimeBar(
                    results: state.results.map { ($0.timestamp, $0.success) },
                    windowSeconds: windowSeconds,
                    width: geo.size.width,
                    height: rowHeight
                )
            }
            .frame(height: rowHeight)

            // Live loss badge
            Text(String(format: "%.0f%% ok", state.successRate * 100))
                .font(.caption2).monospacedDigit()
                .foregroundStyle(state.successRate > 0.95 ? .green : state.successRate > 0.7 ? .yellow : .red)
                .frame(width: 55, alignment: .trailing)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - DNS uptime row

private struct DNSUptimeRow: View {
    @ObservedObject var state: DNSState
    let windowSeconds: Double
    let rowHeight: CGFloat
    let labelWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Text(state.target.domain)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .trailing)

            GeometryReader { geo in
                UptimeBar(
                    results: state.results.map { ($0.timestamp, $0.success) },
                    windowSeconds: windowSeconds,
                    width: geo.size.width,
                    height: rowHeight
                )
            }
            .frame(height: rowHeight)

            Text(String(format: "%.0f%% ok", state.successRate * 100))
                .font(.caption2).monospacedDigit()
                .foregroundStyle(state.successRate > 0.95 ? .green : state.successRate > 0.7 ? .yellow : .red)
                .frame(width: 55, alignment: .trailing)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Canvas-drawn bar

private struct UptimeBar: View {
    let results: [(Date, Bool)]   // (timestamp, success)
    let windowSeconds: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let now   = Date()
            let start = now.addingTimeInterval(-windowSeconds)

            // Background (no-data)
            ctx.fill(
                Path(CGRect(x: 0, y: 0, width: size.width, height: size.height)),
                with: .color(Color(white: 0.22))
            )

            // Filter to window
            let inWindow = results.filter { $0.0 >= start }
            guard !inWindow.isEmpty else { return }

            // Segment width based on expected sample interval (≈1s for ping, 30s for DNS)
            let interval = estimateInterval(inWindow)
            let segW = max(1, CGFloat(interval / windowSeconds) * size.width)

            for (ts, success) in inWindow {
                let age    = now.timeIntervalSince(ts)
                let xRight = size.width - CGFloat(age / windowSeconds) * size.width
                let xLeft  = max(0, xRight - segW)
                let rect   = CGRect(x: xLeft, y: 0, width: xRight - xLeft, height: size.height)
                ctx.fill(Path(rect), with: .color(success ? Color.green.opacity(0.85) : Color.red.opacity(0.9)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func estimateInterval(_ pairs: [(Date, Bool)]) -> Double {
        guard pairs.count >= 2 else { return 1.0 }
        let sorted = pairs.map(\.0).sorted()
        let diffs = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) }
        let median = diffs.sorted()[diffs.count / 2]
        return max(0.5, min(median, 60))
    }
}
