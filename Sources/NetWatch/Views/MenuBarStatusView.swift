import SwiftUI

/// Content displayed in the menu bar extra popover window.
struct MenuBarStatusView: View {
    @EnvironmentObject var monitor:          NetworkMonitorService
    @EnvironmentObject var ifm:              InterfaceMonitor
    @EnvironmentObject var speedTestMonitor: SpeedTestMonitor

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
                ForEach(0..<min(4, monitor.pingStates.count), id: \.self) { i in
                    let ps = monitor.pingStates[i]
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ps.isOnline ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(ps.target.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        MenuBarRTTSparkline(values: ps.recentRTTs, maxVal: 200)
                            .frame(width: 44, height: 14)
                        Text(ps.lastRTT.rttString)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(ps.lastRTT.map { $0 < 50 ? Color.green : $0 < 100 ? Color.yellow : Color.red } ?? Color(NSColor.secondaryLabelColor))
                            .frame(width: 54, alignment: .trailing)
                    }
                }
            }

            if let r = speedTestMonitor.lastResult, r.isSuccess {
                Divider()
                HStack {
                    Image(systemName: "speedometer")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "\u{2193}%.0f  \u{2191}%.0f Mbps \u{00B7} %@",
                                r.downloadMbps, r.uploadMbps, r.quality.label))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(r.timestamp, style: .relative)
                        .font(.caption2).foregroundStyle(.tertiary)
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

// MARK: - MenuBar RTT Sparkline (separate from OverviewView's RTTSparkline — takes raw ms)

private struct MenuBarRTTSparkline: View {
    let values: [Double]
    var maxVal: Double = 100

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cap = max(1, maxVal)
            let n = values.count

            if n >= 2 {
                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(max(1, n - 1))
                        let y = h * (1.0 - CGFloat(min(v, cap) / cap))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else       { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(sparklineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private var sparklineColor: Color {
        guard let last = values.last else { return .secondary }
        if last < 50  { return .green }
        if last < 100 { return .yellow }
        return .red
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
