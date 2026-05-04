import SwiftUI
import Charts

struct TracerouteView: View {
    @EnvironmentObject var trMonitor: TracerouteMonitor
    @EnvironmentObject var monitor: NetworkMonitorService
    @State private var selectedTarget: String? = nil
    @State private var showAddSheet = false

    var targets: [String] { monitor.settings.tracerouteTargets }

    var body: some View {
        HSplitView {
            // Left panel: list + footer
            VStack(spacing: 0) {
                List(targets, id: \.self, selection: $selectedTarget) { target in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Circle()
                                .fill(trMonitor.currentTarget == target && trMonitor.isRunning ? Color.yellow : .green)
                                .frame(width: 8, height: 8)
                            Text(target).font(.body).lineLimit(1)
                        }
                        if let result = trMonitor.results[target] {
                            Text("\(result.hopCount) hops · \(result.timestamp, style: .time)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(target)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            if selectedTarget == target { selectedTarget = nil }
                            monitor.settings.tracerouteTargets.removeAll { $0 == target }
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
                    .help("Add traceroute target")

                    Divider().frame(height: 16).padding(.horizontal, 2)

                    Button {
                        if let t = selectedTarget { trMonitor.runNow(target: t) }
                        else { targets.forEach { trMonitor.runNow(target: $0) } }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(trMonitor.isRunning)
                    .help("Run traceroute now")

                    Spacer()
                }
                .padding(.horizontal, 4)
                .frame(height: 28)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 280)
            .sheet(isPresented: $showAddSheet) {
                TracerouteTargetSheet { host in
                    monitor.settings.tracerouteTargets.append(host)
                    monitor.restart()
                    selectedTarget = host
                }
            }

            // Detail
            Group {
                if let target = selectedTarget, let result = trMonitor.results[target] {
                    TracerouteDetailView(result: result, geoCache: trMonitor.geoCache)
                } else if trMonitor.isRunning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Running traceroute to \(trMonitor.currentTarget)…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(targets.isEmpty ? "Add a target with + above" : "Select a target")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
        .onAppear {
            if selectedTarget == nil { selectedTarget = targets.first }
        }
    }
}

// MARK: - Add Sheet

struct TracerouteTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    let onSave: (String) -> Void

    private var hostTrimmed: String { host.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Traceroute Target").font(.headline)

            Form {
                LabeledContent("Host / IP") {
                    TextField("e.g. 1.1.1.1 or us04web.zoom.us", text: $host)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 240)
                        .onSubmit { saveIfValid() }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { saveIfValid() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hostTrimmed.isEmpty)
            }
            .padding(.horizontal, 4)
        }
        .padding()
        .frame(minWidth: 360, minHeight: 150)
    }

    private func saveIfValid() {
        guard !hostTrimmed.isEmpty else { return }
        onSave(hostTrimmed)
        dismiss()
    }
}

// MARK: - Detail View

struct TracerouteDetailView: View {
    let result: TracerouteResult
    var geoCache: [String: GeoInfo] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("→ \(result.target)", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Spacer()
                    Text("\(result.hopCount) hops · \(result.timestamp, style: .time)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // RTT per hop bar chart
                GroupBox("RTT by Hop") {
                    Chart {
                        ForEach(result.hops.filter { !$0.isTimeout }) { hop in
                            if let rtt = hop.avgRTT {
                                BarMark(x: .value("Hop", hop.id), y: .value("RTT", rtt))
                                    .foregroundStyle(hopColor(rtt))
                                    .cornerRadius(3)
                            }
                        }
                    }
                    .chartXAxisLabel("Hop")
                    .chartYAxisLabel("Avg RTT (ms)")
                    .frame(height: 120)
                }

                // Hop table
                GroupBox("Hops") {
                    VStack(spacing: 0) {
                        // header
                        HStack {
                            Text("#").frame(width: 28, alignment: .trailing)
                            Text("IP / Host").frame(minWidth: 130, alignment: .leading)
                            Text("RTT 1").frame(width: 70, alignment: .trailing)
                            Text("RTT 2").frame(width: 70, alignment: .trailing)
                            Text("RTT 3").frame(width: 70, alignment: .trailing)
                            Text("Avg").frame(width: 70, alignment: .trailing)
                            Text("ASN / Location").frame(minWidth: 160, alignment: .leading)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        Divider()

                        ForEach(result.hops) { hop in
                            HStack {
                                Text("\(hop.id)")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 28, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                                Text(hop.ip ?? "*")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minWidth: 130, alignment: .leading)
                                    .lineLimit(1)
                                rttCell(hop.rtt1, width: 70)
                                rttCell(hop.rtt2, width: 70)
                                rttCell(hop.rtt3, width: 70)
                                rttCell(hop.avgRTT, width: 70)
                                // Geo annotation
                                if let ip = hop.ip, let geo = geoCache[ip] {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(geo.asnShort)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(geo.location)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(minWidth: 160, alignment: .leading)
                                } else {
                                    Text(hop.ip == nil ? "" : "–")
                                        .frame(minWidth: 160, alignment: .leading)
                                        .foregroundStyle(.secondary)
                                        .font(.caption2)
                                }
                            }
                            .padding(.vertical, 4)
                            Divider().opacity(0.4)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                ClaudeCompanionCard(
                    context: tracerouteClaudeContext(),
                    promptHint: tracerouteClaudeHint()
                )

                Spacer()
            }
            .padding(20)
        }
    }

    private func tracerouteClaudeContext() -> String {
        var lines = [
            "## NetWatch Traceroute — \(result.target)",
            "\(result.hopCount) hops | Completed: \(result.timestamp.formatted(date: .omitted, time: .shortened))"
        ]
        let reachableHops = result.hops.filter { !$0.isTimeout }
        if let lastHop = reachableHops.last, let rtt = lastHop.avgRTT {
            lines.append(String(format: "Final RTT to destination: %.1f ms", rtt))
        }
        let timeouts = result.hops.filter { $0.isTimeout }.count
        if timeouts > 0 {
            lines.append("\(timeouts) hops timed out (* * *)")
        }
        lines.append("")
        lines.append("Hop breakdown:")
        for hop in result.hops {
            let ip = hop.ip ?? "*"
            if hop.isTimeout {
                lines.append("  Hop \(hop.id): * * * (timeout)")
            } else {
                let rttStr = hop.avgRTT.map { String(format: "%.1f ms avg", $0) } ?? "–"
                var line = "  Hop \(hop.id): \(ip) — \(rttStr)"
                if let ip = hop.ip, let geo = geoCache[ip] {
                    line += " [\(geo.asnShort), \(geo.location)]"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func tracerouteClaudeHint() -> String {
        let timeouts = result.hops.filter { $0.isTimeout }.count
        if timeouts > result.hopCount / 2 {
            return "More than half the hops in my traceroute to \(result.target) timed out. Does that mean there's an actual problem, or is that normal?"
        }
        if let lastReachable = result.hops.filter({ !$0.isTimeout }).last,
           let rtt = lastReachable.avgRTT, rtt > 100 {
            return String(format: "Traceroute to %@ shows %.0f ms at hop %d. Where is the latency being added?", result.target, rtt, lastReachable.id)
        }
        return "Interpret this traceroute to \(result.target) — is the path healthy and are any hops concerning?"
    }

    @ViewBuilder
    func rttCell(_ rtt: Double?, width: CGFloat = 80) -> some View {
        if let r = rtt {
            Text(String(format: "%.1f ms", r))
                .frame(width: width, alignment: .trailing)
                .foregroundStyle(hopColor(r))
                .font(.system(.callout, design: .monospaced))
        } else {
            Text("*")
                .frame(width: width, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.system(.callout, design: .monospaced))
        }
    }

    func hopColor(_ rtt: Double) -> Color {
        rtt < 20 ? .green : rtt < 60 ? .yellow : rtt < 150 ? .orange : .red
    }
}
