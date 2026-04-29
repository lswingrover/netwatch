import SwiftUI

/// Content displayed in the menu bar extra popover window.
struct MenuBarStatusView: View {
    @EnvironmentObject var monitor: NetworkMonitorService
    @EnvironmentObject var ifm: InterfaceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // ── Header ────────────────────────────────────────────────────────
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text("Network \(monitor.overallStatus.label)")
                    .font(.headline)
                Spacer()
                Text(Date(), style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider()

            // ── Throughput ────────────────────────────────────────────────────
            VStack(spacing: 4) {
                MBRow(label: "↓  Download",
                      value: "\(ifm.currentRate.rxBytesPerSec.humanBytes)/s",
                      color: .blue)
                MBRow(label: "↑  Upload",
                      value: "\(ifm.currentRate.txBytesPerSec.humanBytes)/s",
                      color: .orange)
            }

            // ── Gateway + DNS ─────────────────────────────────────────────────
            if let rtt = ifm.gatewayRTT {
                let c: Color = rtt < 50 ? .green : rtt < 100 ? .yellow : .red
                MBRow(label: "⇢  Gateway RTT", value: rtt.rttString, color: c)
            }

            // ── Wi-Fi ─────────────────────────────────────────────────────────
            if !ifm.wifiSSID.isEmpty {
                Divider()
                MBRow(label: "  \(ifm.wifiSSID)",
                      value: "\(ifm.wifiRSSI) dBm · ch \(ifm.wifiChannel)",
                      color: rssiColor)
                MBRow(label: "  Tx rate",
                      value: "MCS\(ifm.wifiMCS)  \(ifm.wifiTxRate) Mbps",
                      color: .secondary)
            }

            // ── Ping quick-glance ─────────────────────────────────────────────
            Divider()
            VStack(spacing: 4) {
                ForEach(monitor.pingStates.prefix(4)) { ps in
                    HStack {
                        Circle()
                            .fill(ps.isOnline ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(ps.target.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(ps.lastRTT.rttString)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(ps.lastRTT.map { $0 < 50 ? Color.green : $0 < 100 ? .yellow : .red } ?? .secondary)
                    }
                }
            }

            // ── Actions ────────────────────────────────────────────────────────
            Divider()
            HStack {
                Button(monitor.isRunning ? "Pause" : "Resume") {
                    if monitor.isRunning { monitor.stop() } else { monitor.start() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                Button("Open NetWatch") {
                    NSApp.activate(ignoringOtherApps: true)
                    for w in NSApp.windows where !w.title.isEmpty { w.makeKeyAndOrderFront(nil) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 270)
    }

    var statusColor: Color {
        switch monitor.overallStatus {
        case .healthy:  .green
        case .degraded: .yellow
        case .critical: .red
        }
    }

    var rssiColor: Color {
        ifm.wifiRSSI >= -60 ? .green : ifm.wifiRSSI >= -75 ? .yellow : .red
    }
}

private struct MBRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 110, alignment: .leading)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}
