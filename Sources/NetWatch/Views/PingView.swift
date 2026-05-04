import SwiftUI
import Charts

struct PingView: View {
    @EnvironmentObject var monitor: NetworkMonitorService
    @State private var selectedID: String? = nil
    @State private var showAddSheet  = false
    @State private var editTarget: PingTarget? = nil

    var selectedState: PingState? {
        monitor.pingStates.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            // Left panel: list + footer add button
            VStack(spacing: 0) {
                List(monitor.pingStates, selection: $selectedID) { ps in
                    PingListRow(state: ps)
                        .tag(ps.id)
                        .contextMenu {
                            Button("Edit…") { editTarget = ps.target }
                            Divider()
                            Button("Delete", role: .destructive) {
                                if selectedID == ps.id { selectedID = nil }
                                monitor.settings.pingTargets.removeAll { $0.host == ps.target.host }
                                monitor.restart()
                            }
                        }
                }
                .listStyle(.sidebar)

                // macOS source-list footer — + button lives in the panel, not the toolbar
                Divider()
                HStack(spacing: 0) {
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add ping target  (⌘+N also works)")
                    Spacer()
                }
                .padding(.horizontal, 4)
                .frame(height: 28)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
            .sheet(isPresented: $showAddSheet) {
                PingTargetSheet(title: "Add Ping Target", host: "", label: "") { host, label in
                    monitor.settings.pingTargets.append(
                        PingTarget(host: host, label: label.isEmpty ? nil : label)
                    )
                    monitor.restart()
                }
            }
            .sheet(item: $editTarget) { target in
                PingTargetSheet(title: "Edit Ping Target",
                                host: target.host,
                                label: target.label ?? "") { newHost, newLabel in
                    if let idx = monitor.settings.pingTargets.firstIndex(where: { $0.host == target.host }) {
                        monitor.settings.pingTargets[idx].host  = newHost
                        monitor.settings.pingTargets[idx].label = newLabel.isEmpty ? nil : newLabel
                        if selectedID == target.host { selectedID = newHost }
                        monitor.restart()
                    }
                }
            }

            // Right: detail
            if let ps = selectedState {
                PingDetailView(state: ps)
                    .id(ps.id)
                    .frame(minWidth: 460)
            } else {
                Text("Select a target")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Add / Edit Sheet

struct PingTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State private var host:  String
    @State private var label: String
    let onSave: (String, String) -> Void

    init(title: String, host: String, label: String, onSave: @escaping (String, String) -> Void) {
        self.title  = title
        self.onSave = onSave
        _host  = State(initialValue: host)
        _label = State(initialValue: label)
    }

    private var hostTrimmed: String { host.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)

            Form {
                LabeledContent("Host / IP") {
                    TextField("e.g. 1.1.1.1 or router.local", text: $host)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 220)
                        .onSubmit { saveIfValid() }
                }
                LabeledContent("Label") {
                    TextField("optional — shown in sidebar", text: $label)
                        .frame(minWidth: 220)
                        .onSubmit { saveIfValid() }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { saveIfValid() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hostTrimmed.isEmpty)
            }
            .padding(.horizontal, 4)
        }
        .padding()
        .frame(minWidth: 380, minHeight: 200)
    }

    private func saveIfValid() {
        guard !hostTrimmed.isEmpty else { return }
        onSave(hostTrimmed, label.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}

// MARK: - List Row

struct PingListRow: View {
    @ObservedObject var state: PingState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.isOnline ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.target.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(state.lastRTT.rttString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if !state.recentRTTs.isEmpty {
                MiniRTTSparkline(data: state.recentRTTs)
                    .frame(width: 48, height: 20)
            } else {
                Text(state.trend.symbol).font(.caption)
            }
        }
    }
}

private struct MiniRTTSparkline: View {
    let data: [Double]
    var body: some View {
        Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("t", i), y: .value("rtt", v))
                    .foregroundStyle(v < 50 ? Color.green : v < 100 ? Color.yellow : Color.red)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

// MARK: - Detail View

struct PingDetailView: View {
    @ObservedObject var state: PingState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header stats — row 1: primary
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    StatCard(title: "Last RTT",  value: state.lastRTT.rttString,
                             icon: "timer",     color: rttColor(state.lastRTT))
                    StatCard(title: "Avg RTT",   value: state.avgRTT.rttString,
                             icon: "chart.line.uptrend.xyaxis")
                    StatCard(title: "Packet Loss",
                             value: String(format: "%.1f%%", (1 - state.successRate) * 100),
                             icon: "wifi.exclamationmark",
                             color: state.successRate > 0.95 ? .green : .red)
                }
                // Header stats — row 2: forensics
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    StatCard(title: "Jitter",
                             value: state.jitter.rttString,
                             icon: "waveform.path.ecg",
                             color: (state.jitter ?? 0) < 10 ? .green : (state.jitter ?? 0) < 30 ? .yellow : .red)
                    StatCard(title: "Min RTT",
                             value: state.minRTT.rttString,
                             icon: "arrow.down.to.line")
                    StatCard(title: "Max RTT",
                             value: state.maxRTT.rttString,
                             icon: "arrow.up.to.line",
                             color: rttColor(state.maxRTT))
                }
                // Header stats — row 2b: secondary
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    StatCard(title: "Samples",
                             value: "\(state.results.count)",
                             icon: "number")
                    StatCard(title: "Trend",     value: state.trend.symbol,
                             icon: "arrow.up.right")
                    StatCard(title: "Success Rate",
                             value: String(format: "%.1f%%", state.successRate * 100),
                             icon: "checkmark.circle",
                             color: state.successRate > 0.95 ? .green : state.successRate > 0.7 ? .yellow : .red)
                }
                // Header stats — row 3: percentiles
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    StatCard(title: "p50 (median)",
                             value: state.p50.rttString,
                             icon: "chart.line.flattrend.xyaxis",
                             color: rttColor(state.p50))
                    StatCard(title: "p95",
                             value: state.p95.rttString,
                             icon: "chart.line.uptrend.xyaxis",
                             color: rttColor(state.p95))
                    StatCard(title: "p99",
                             value: state.p99.rttString,
                             icon: "exclamationmark.arrow.triangle.2.circlepath",
                             color: rttColor(state.p99))
                }

                // RTT chart
                GroupBox("RTT History") {
                    Chart {
                        ForEach(Array(state.results.suffix(60).enumerated()), id: \.offset) { i, r in
                            if r.success, let rtt = r.rtt {
                                LineMark(x: .value("Sample", i), y: .value("RTT", rtt))
                                    .foregroundStyle(rttColor(rtt))
                                PointMark(x: .value("Sample", i), y: .value("RTT", rtt))
                                    .foregroundStyle(rttColor(rtt))
                                    .symbolSize(20)
                            } else {
                                RuleMark(x: .value("Sample", i))
                                    .foregroundStyle(.red.opacity(0.3))
                                    .lineStyle(StrokeStyle(dash: [2, 4]))
                            }
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxisLabel("RTT (ms)")
                    .frame(height: 140)
                }

                // Recent results log
                GroupBox("Recent Results") {
                    VStack(spacing: 0) {
                        ForEach(state.results.suffix(30).reversed()) { r in
                            HStack {
                                Text(r.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 70, alignment: .leading)
                                Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(r.success ? .green : .red)
                                    .font(.caption)
                                Text(r.rtt.rttString)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(rttColor(r.rtt))
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            Divider().opacity(0.3)
                        }
                    }
                    .frame(maxHeight: 300)
                }

                ClaudeCompanionCard(
                    context: pingClaudeContext(),
                    promptHint: pingClaudeHint()
                )

                Spacer()
            }
            .padding(20)
        }
        .navigationTitle(state.target.displayName)
    }

    func rttColor(_ rtt: Double?) -> Color {
        guard let r = rtt else { return .secondary }
        return r < 50 ? .green : r < 100 ? .yellow : .red
    }

    func rttColor(_ rtt: Double) -> Color {
        rtt < 50 ? .green : rtt < 100 ? .yellow : .red
    }

    private func pingClaudeContext() -> String {
        let loss = (1 - state.successRate) * 100
        var lines = [
            "## NetWatch Ping Monitor — \(state.target.displayName)",
            String(format: "Last RTT: %@ | Avg: %@ | Jitter: %@",
                   state.lastRTT.rttString, state.avgRTT.rttString, state.jitter.rttString),
            String(format: "Packet Loss: %.1f%% | Success Rate: %.1f%%", loss, state.successRate * 100),
            String(format: "Min: %@ | Max: %@", state.minRTT.rttString, state.maxRTT.rttString),
            String(format: "p50: %@ | p95: %@ | p99: %@",
                   state.p50.rttString, state.p95.rttString, state.p99.rttString),
            "Trend: \(state.trend.symbol) | Samples: \(state.results.count)"
        ]
        let recentFailures = state.results.suffix(10).filter { !$0.success }.count
        if recentFailures > 0 {
            lines.append("\(recentFailures)/10 recent pings failed")
        }
        return lines.joined(separator: "\n")
    }

    private func pingClaudeHint() -> String {
        let loss = (1 - state.successRate) * 100
        if loss > 10 {
            return String(format: "%.1f%% packet loss to %@. Is this a routing problem, ISP issue, or something local?", loss, state.target.displayName)
        }
        if let jitter = state.jitter, jitter > 20 {
            return String(format: "Jitter is %.1f ms to %@. What causes high jitter and does it affect my network?", jitter, state.target.displayName)
        }
        if let rtt = state.avgRTT, rtt > 100 {
            return String(format: "Average RTT is %.0f ms to %@. Is that too high for my use case?", rtt, state.target.displayName)
        }
        return "Ping stats to \(state.target.displayName): are these healthy or should I be concerned about anything?"
    }
}
