import SwiftUI
import Charts

struct DNSView: View {
    @EnvironmentObject var monitor: NetworkMonitorService
    @State private var selectedID: String? = nil
    @State private var showAddSheet  = false
    @State private var editTarget: DNSTarget? = nil

    var selectedState: DNSState? {
        monitor.dnsStates.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            // Left panel: list + footer add button
            VStack(spacing: 0) {
                List(monitor.dnsStates, selection: $selectedID) { ds in
                    DNSListRow(state: ds)
                        .tag(ds.id)
                        .contextMenu {
                            Button("Edit Domain…") { editTarget = ds.target }
                            Divider()
                            Button("Delete", role: .destructive) {
                                if selectedID == ds.id { selectedID = nil }
                                monitor.settings.dnsTargets.removeAll { $0.domain == ds.target.domain }
                                monitor.restart()
                            }
                        }
                }
                .listStyle(.sidebar)

                Divider()
                HStack(spacing: 0) {
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add DNS domain")
                    Spacer()
                }
                .padding(.horizontal, 4)
                .frame(height: 28)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)
            .sheet(isPresented: $showAddSheet) {
                DNSTargetSheet(title: "Add DNS Domain", domain: "") { domain in
                    monitor.settings.dnsTargets.append(DNSTarget(domain: domain))
                    monitor.restart()
                }
            }
            .sheet(item: $editTarget) { target in
                DNSTargetSheet(title: "Edit DNS Domain", domain: target.domain) { newDomain in
                    if let idx = monitor.settings.dnsTargets.firstIndex(where: { $0.domain == target.domain }) {
                        monitor.settings.dnsTargets[idx].domain = newDomain
                        if selectedID == target.domain { selectedID = newDomain }
                        monitor.restart()
                    }
                }
            }

            if let ds = selectedState {
                DNSDetailView(state: ds).id(ds.id)
                    .frame(minWidth: 380)
            } else {
                Text("Select a domain")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Add / Edit Sheet

struct DNSTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State private var domain: String
    let onSave: (String) -> Void

    init(title: String, domain: String, onSave: @escaping (String) -> Void) {
        self.title  = title
        self.onSave = onSave
        _domain = State(initialValue: domain)
    }

    private var domainTrimmed: String { domain.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)

            Form {
                LabeledContent("Domain") {
                    TextField("e.g. github.com", text: $domain)
                        .font(.system(.body, design: .monospaced))
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
                    .disabled(domainTrimmed.isEmpty)
            }
            .padding(.horizontal, 4)
        }
        .padding()
        .frame(minWidth: 340, minHeight: 160)
    }

    private func saveIfValid() {
        guard !domainTrimmed.isEmpty else { return }
        onSave(domainTrimmed)
        dismiss()
    }
}

// MARK: - List Row

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

// MARK: - Detail View

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
