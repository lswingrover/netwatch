import SwiftUI
import Charts

struct DNSView: View {
    @EnvironmentObject var monitor: NetworkMonitorService
    @State private var selectedID: String? = nil

    var selectedState: DNSState? {
        monitor.dnsStates.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            List(monitor.dnsStates, selection: $selectedID) { ds in
                DNSListRow(state: ds).tag(ds.id)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 220)

            if let ds = selectedState {
                DNSDetailView(state: ds).id(ds.id)
            } else {
                Text("Select a domain")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct DNSListRow: View {
    @ObservedObject var state: DNSState
    var body: some View {
        HStack {
            Circle()
                .fill(state.successRate > 0.9 ? Color.green : state.successRate > 0.7 ? .yellow : .red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.target.domain).font(.body).lineLimit(1)
                Text(state.lastQueryTime.rttString)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Text(String(format: "%.0f%%", state.successRate * 100))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DNSDetailView: View {
    @ObservedObject var state: DNSState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    StatCard(title: "Last Query", value: state.lastQueryTime.rttString,
                             icon: "clock", color: qColor(state.lastQueryTime))
                    StatCard(title: "Avg Query",  value: state.avgQueryTime.rttString,
                             icon: "chart.bar")
                    StatCard(title: "Success Rate",
                             value: String(format: "%.1f%%", state.successRate * 100),
                             icon: "checkmark.shield",
                             color: state.successRate > 0.95 ? .green : .red)
                }

                GroupBox("Query Time History") {
                    Chart {
                        ForEach(Array(state.results.suffix(40).enumerated()), id: \.offset) { i, r in
                            if r.success, let qt = r.queryTime {
                                BarMark(x: .value("Sample", i), y: .value("ms", qt))
                                    .foregroundStyle(qColor(qt))
                            } else {
                                RuleMark(x: .value("Sample", i))
                                    .foregroundStyle(.red.opacity(0.5))
                            }
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxisLabel("Query Time (ms)")
                    .frame(height: 120)
                }

                // Multi-resolver comparison
                if !state.resolverTimes.isEmpty {
                    GroupBox("Resolver Comparison (last query)") {
                        VStack(spacing: 0) {
                            ForEach(["System", "Cloudflare", "Google", "Quad9"], id: \.self) { label in
                                if let timing = state.resolverTimes[label] {
                                    HStack {
                                        Text(label)
                                            .font(.system(.body, design: .monospaced))
                                            .frame(width: 100, alignment: .leading)
                                        if let ms = timing {
                                            // proportional bar
                                            let maxMs = state.resolverTimes.values
                                                .compactMap { $0 }.max() ?? 1
                                            GeometryReader { geo in
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(resolverBarColor(ms))
                                                    .frame(width: max(4, geo.size.width * (ms / maxMs)))
                                                    .frame(maxHeight: .infinity)
                                            }
                                            .frame(height: 14)
                                            Text(Optional(ms).rttString)
                                                .font(.system(.callout, design: .monospaced))
                                                .foregroundStyle(resolverBarColor(ms))
                                                .frame(width: 90, alignment: .trailing)
                                        } else {
                                            Text("TIMEOUT")
                                                .foregroundStyle(.red)
                                                .font(.callout)
                                            Spacer()
                                        }
                                    }
                                    .padding(.vertical, 5)
                                    Divider().opacity(0.3)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }

                GroupBox("Recent Results") {
                    VStack(spacing: 0) {
                        ForEach(state.results.suffix(30).reversed()) { r in
                            DNSResultRow(result: r)
                            Divider().opacity(0.3)
                        }
                    }
                    .frame(maxHeight: 300)
                }

                Spacer()
            }
            .padding(20)
        }
        .navigationTitle(state.target.domain)
    }

    func qColor(_ t: Double?) -> Color {
        guard let v = t else { return .secondary }
        return v < 50 ? .green : v < 150 ? .yellow : .red
    }
    func qColor(_ t: Double) -> Color { t < 50 ? .green : t < 150 ? .yellow : .red }
    func resolverBarColor(_ ms: Double) -> Color { ms < 30 ? .green : ms < 100 ? .blue : ms < 300 ? .yellow : .red }
}

private struct DNSResultRow: View {
    let result: DNSResult
    var body: some View {
        HStack {
            Text(result.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
                .frame(width: 70, alignment: .leading)
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? Color.green : Color.red)
                .font(.caption)
            Text(result.queryTime.rttString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(qtColor(result.queryTime))
            Spacer()
            Text(result.status)
                .font(.caption2)
                .foregroundStyle(result.success ? Color.secondary : Color.red)
        }
        .padding(.vertical, 2)
    }

    private func qtColor(_ t: Double?) -> Color {
        guard let v = t else { return .secondary }
        return v < 50 ? .green : v < 150 ? .yellow : .red
    }
}
