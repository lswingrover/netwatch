import SwiftUI
import Charts

struct TracerouteView: View {
    @EnvironmentObject var trMonitor: TracerouteMonitor
    @EnvironmentObject var monitor: NetworkMonitorService
    @State private var selectedTarget: String? = nil

    var targets: [String] { monitor.settings.tracerouteTargets }

    var body: some View {
        HSplitView {
            // Target list
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
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 200)
            .toolbar {
                ToolbarItem {
                    Button {
                        if let t = selectedTarget { trMonitor.runNow(target: t) }
                        else { targets.forEach { trMonitor.runNow(target: $0) } }
                    } label: {
                        Label("Run Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(trMonitor.isRunning)
                    .help("Run traceroute immediately")
                }
            }

            // Detail
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
                Text(targets.isEmpty ? "Add targets in Preferences" : "Select a target")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedTarget == nil { selectedTarget = targets.first }
        }
    }
}

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

                Spacer()
            }
            .padding(20)
        }
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
