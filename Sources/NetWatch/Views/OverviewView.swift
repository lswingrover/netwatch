import SwiftUI
import Charts

struct OverviewView: View {
    @EnvironmentObject var monitor:       NetworkMonitorService
    @EnvironmentObject var ifm:           InterfaceMonitor
    @EnvironmentObject var updateChecker: UpdateChecker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Update banner (shown when a new version is available)
                if updateChecker.updateAvailable {
                    UpdateBanner(checker: updateChecker)
                }

                // Status banner
                StatusBanner()

                // Interface card row
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                    GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(title: "Interface",     value: ifm.interface.isEmpty ? "–" : ifm.interface, icon: "wifi")
                    StatCard(title: "IP Address",    value: ifm.ipAddress.isEmpty ? "–" : ifm.ipAddress, icon: "network")
                    StatCard(title: "Gateway",       value: ifm.gateway.isEmpty ? "–" : ifm.gateway, icon: "arrow.triangle.branch")
                    StatCard(title: "Public IP",     value: ifm.publicIP.isEmpty ? "…" : ifm.publicIP, icon: "globe")
                }

                // Throughput row
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                    GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(title: "↓ Download",   value: "\(ifm.currentRate.rxBytesPerSec.humanBytes)/s",  icon: "arrow.down.circle", color: .blue)
                    StatCard(title: "↑ Upload",     value: "\(ifm.currentRate.txBytesPerSec.humanBytes)/s",  icon: "arrow.up.circle",   color: .orange)
                    StatCard(title: "Gateway RTT",  value: ifm.gatewayRTT.rttString, icon: "waveform.path", color: rttColor(ifm.gatewayRTT))
                    StatCard(title: "TCP Sessions", value: "\(ifm.tcpEstablished)",  icon: "arrow.2.circlepath")
                }

                // Interface forensics row
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                    GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(title: "RX Errors",   value: "\(ifm.currentRate.rxErrors)", icon: "exclamationmark.arrow.triangle.2.circlepath",
                             color: ifm.currentRate.rxErrors == 0 ? .green : .red)
                    StatCard(title: "TX Errors",   value: "\(ifm.currentRate.txErrors)", icon: "exclamationmark.arrow.triangle.2.circlepath",
                             color: ifm.currentRate.txErrors == 0 ? .green : .red)
                    StatCard(title: "MTU",         value: ifm.mtu > 0 ? "\(ifm.mtu) B" : "–", icon: "ruler")
                    StatCard(title: "RX Packets/s",value: "\(Int(ifm.currentRate.rxPacketsPerSec)) pkt/s", icon: "tray.and.arrow.down")
                }

                // Wi-Fi row (only shown when on Wi-Fi)
                if !ifm.wifiSSID.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                        GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatCard(title: "Wi-Fi SSID",   value: ifm.wifiSSID,               icon: "wifi")
                        StatCard(title: "Signal (RSSI)", value: "\(ifm.wifiRSSI) dBm",     icon: "wifi.circle",
                                 color: ifm.wifiRSSI >= -60 ? .green : ifm.wifiRSSI >= -75 ? .yellow : .red)
                        StatCard(title: "Noise Floor",  value: "\(ifm.wifiNoise) dBm",     icon: "waveform")
                        StatCard(title: "MCS / Tx Rate",value: "MCS\(ifm.wifiMCS)  \(ifm.wifiTxRate) Mbps", icon: "speedometer")
                    }
                    // Second Wi-Fi row: SNR + retries
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                        GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatCard(title: "SNR",
                                 value: "\(ifm.wifiSNR) dB",
                                 icon: "waveform.badge.magnifyingglass",
                                 color: ifm.wifiSNR >= 25 ? .green : ifm.wifiSNR >= 15 ? .yellow : .red)
                        StatCard(title: "Retry Rate",
                                 value: String(format: "%.1f%%", ifm.wifiRetryRate * 100),
                                 icon: "arrow.counterclockwise.circle",
                                 color: ifm.wifiRetryRate < 0.05 ? .green : ifm.wifiRetryRate < 0.15 ? .yellow : .red)
                        StatCard(title: "Link Flaps",
                                 value: "\(ifm.linkFlaps.count)",
                                 icon: "bolt.trianglebadge.exclamationmark",
                                 color: ifm.linkFlaps.isEmpty ? .green : .orange)
                        StatCard(title: "Link State",
                                 value: ifm.interfaceUp ? "Up" : "Down",
                                 icon: ifm.interfaceUp ? "checkmark.circle.fill" : "xmark.circle.fill",
                                 color: ifm.interfaceUp ? .green : .red)
                    }
                }

                // Link flap log
                if !ifm.linkFlaps.isEmpty {
                    GroupBox("Link Flap Log (last \(ifm.linkFlaps.count))") {
                        VStack(spacing: 0) {
                            ForEach(ifm.linkFlaps.prefix(10)) { flap in
                                HStack {
                                    Image(systemName: flap.event == "down" ? "xmark.circle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(flap.event == "down" ? Color.red : Color.green)
                                        .font(.caption)
                                    Text(flap.event == "down" ? "Interface went DOWN" : "Interface came UP")
                                        .font(.callout)
                                    Spacer()
                                    Text(flap.timestamp, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                                Divider().opacity(0.3)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }

                // Gateway RTT sparkline
                if !ifm.rttHistory.isEmpty {
                    GroupBox("Gateway RTT History (last \(ifm.rttHistory.count) samples)") {
                        RTTSparkline(data: ifm.rttHistory)
                            .frame(height: 80)
                    }
                }

                // Bandwidth history chart
                if !ifm.bandwidthHistory.isEmpty {
                    GroupBox("Bandwidth History (\(ifm.bandwidthHistory.count)s window)") {
                        BandwidthHistoryChart(history: ifm.bandwidthHistory)
                            .frame(height: 100)
                    }
                }

                // Ping summary table
                GroupBox("Ping Summary") {
                    PingSummaryTable()
                }

                // DNS summary
                GroupBox("DNS Summary") {
                    DNSSummaryTable()
                }

                Spacer()
            }
            .padding(20)
        }
    }

    func rttColor(_ rtt: Double?) -> Color {
        guard let r = rtt else { return .primary }
        if r < 50 { return .green }
        if r < 100 { return .yellow }
        return .red
    }
}

// MARK: - Status Banner

struct StatusBanner: View {
    @EnvironmentObject var monitor: NetworkMonitorService

    var body: some View {
        HStack {
            Image(systemName: monitor.overallStatus.systemImage)
                .font(.title2)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Network \(monitor.overallStatus.label)")
                    .font(.headline)
                Text(monitor.isRunning ? "Monitoring active" : "Monitoring paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Date(), style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(12)
        .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    var statusColor: Color {
        switch monitor.overallStatus {
        case .healthy:  .green
        case .degraded: .yellow
        case .critical: .red
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .primary

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - RTT Sparkline

struct RTTSparkline: View {
    let data: [Double]

    var body: some View {
        Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { i, val in
                LineMark(x: .value("t", i), y: .value("RTT", val))
                    .foregroundStyle(lineColor(val))
                AreaMark(x: .value("t", i), y: .value("RTT", val))
                    .foregroundStyle(lineColor(val).opacity(0.15))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { val in
                AxisValueLabel { if let v = val.as(Double.self) { Text("\(Int(v))ms").font(.caption2) } }
            }
        }
    }

    func lineColor(_ rtt: Double) -> Color {
        if rtt < 50 { return .green }
        if rtt < 100 { return .yellow }
        return .red
    }
}

// MARK: - Bandwidth History Chart

struct BandwidthHistoryChart: View {
    let history: [BandwidthSample]

    var body: some View {
        Chart {
            ForEach(Array(history.enumerated()), id: \.offset) { i, s in
                AreaMark(x: .value("t", i), y: .value("RX", s.rxBytesPerSec))
                    .foregroundStyle(.blue.opacity(0.45))
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("t", i), y: .value("TX", s.txBytesPerSec))
                    .foregroundStyle(.orange.opacity(0.45))
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { val in
                AxisValueLabel {
                    if let v = val.as(Double.self) { Text(v.humanBytes).font(.caption2) }
                }
                AxisGridLine()
            }
        }
        .chartLegend(position: .topTrailing) {
            HStack(spacing: 8) {
                Circle().fill(.blue).frame(width: 6, height: 6)
                Text("↓ RX").font(.caption2)
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text("↑ TX").font(.caption2)
            }
        }
    }
}

// MARK: - Ping Summary Table

struct PingSummaryTable: View {
    @EnvironmentObject var monitor: NetworkMonitorService

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Target").frame(width: 150, alignment: .leading)
                Text("Avg RTT").frame(width: 70, alignment: .trailing)
                Text("Min").frame(width: 60, alignment: .trailing)
                Text("Max").frame(width: 60, alignment: .trailing)
                Text("Jitter").frame(width: 60, alignment: .trailing)
                Text("Loss").frame(width: 55, alignment: .trailing)
                Text("Status").frame(width: 55, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)

            Divider()

            ForEach(monitor.pingStates) { ps in
                PingSummaryRow(state: ps)
                Divider().opacity(0.4)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct PingSummaryRow: View {
    @ObservedObject var state: PingState

    var body: some View {
        HStack {
            Text(state.target.displayName)
                .font(.system(.body, design: .monospaced))
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            Text(state.avgRTT.rttString)
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(rttColor(state.avgRTT))
            Text(state.minRTT.rttString)
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(Color.green.opacity(0.9))
            Text(state.maxRTT.rttString)
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(rttColor(state.maxRTT))
            Text(state.jitter.rttString)
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(jitterColor)
            Text(lossText)
                .frame(width: 55, alignment: .trailing)
                .foregroundStyle(lossColor)
            HStack(spacing: 4) {
                Circle()
                    .fill(state.isOnline ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(state.isOnline ? "OK" : "FAIL")
                    .foregroundStyle(state.isOnline ? Color.green : Color.red)
            }
            .frame(width: 55, alignment: .trailing)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 5)
    }

    var lossText: String { String(format: "%.0f%%", (1 - state.successRate) * 100) }
    var lossColor: Color { state.successRate > 0.95 ? .green : state.successRate > 0.8 ? .yellow : .red }
    var jitterColor: Color {
        guard let j = state.jitter else { return .secondary }
        return j < 10 ? .green : j < 30 ? .yellow : .red
    }
    func rttColor(_ rtt: Double?) -> Color {
        guard let r = rtt else { return .secondary }
        return r < 50 ? .green : r < 100 ? .yellow : .red
    }
}

// MARK: - DNS Summary Table

struct DNSSummaryTable: View {
    @EnvironmentObject var monitor: NetworkMonitorService

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Domain").frame(width: 200, alignment: .leading)
                Text("Avg").frame(width: 80, alignment: .trailing)
                Text("Last").frame(width: 80, alignment: .trailing)
                Text("Success").frame(width: 70, alignment: .trailing)
                Text("Status").frame(width: 70, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)

            Divider()

            ForEach(monitor.dnsStates) { ds in
                DNSSummaryRow(state: ds)
                Divider().opacity(0.4)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct DNSSummaryRow: View {
    @ObservedObject var state: DNSState

    var body: some View {
        HStack {
            Text(state.target.domain)
                .font(.system(.body, design: .monospaced))
                .frame(width: 200, alignment: .leading)
            Text(state.avgQueryTime.rttString)
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(rttColor(state.avgQueryTime))
            Text(state.lastQueryTime.rttString)
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(rttColor(state.lastQueryTime))
            Text(String(format: "%.1f%%", state.successRate * 100))
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(state.successRate > 0.95 ? .green : .yellow)
            Text(state.lastStatus)
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(state.lastStatus == "NOERROR" ? .green : .red)
                .lineLimit(1)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 5)
    }

    func rttColor(_ rtt: Double?) -> Color {
        guard let r = rtt else { return .secondary }
        return r < 50 ? .green : r < 150 ? .yellow : .red
    }
}

// MARK: - Update Banner

struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.white)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("NetWatch \(checker.latestVersion) is available")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("A new version is on GitHub.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            if let url = checker.releaseURL {
                Button("View Release") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            Button {
                checker.updateAvailable = false
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor)
        )
    }
}
