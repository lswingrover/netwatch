/// NighthawkIntelligenceView.swift — Rich Netgear Nighthawk panel
///
/// Tabs:
///   Overview  — Summary tiles (WAN, clients, traffic, Ethernet ports)
///   Metrics   — Full metric grid with sparklines
///   Events    — Connector event list
///   History   — ConnectorTimelineView trend chart
///
/// Mirrors the structure of OrbiIntelligenceView. Reads NighthawkConnector
/// metrics directly from the ConnectorSnapshot — no custom summary struct needed.

import SwiftUI

struct NighthawkIntelligenceView: View {
    @EnvironmentObject var connectorManager: ConnectorManager

    private var nighthawk: NightawkConnector? {
        connectorManager.connectors.first(where: { $0.id == "nighthawk" }) as? NightawkConnector
    }

    private var snapshot: ConnectorSnapshot? {
        connectorManager.snapshot(for: "nighthawk")
    }

    @State private var tab: NHTab = .overview

    enum NHTab: String, CaseIterable {
        case overview = "Overview"
        case metrics  = "Metrics"
        case events   = "Events"
        case history  = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            if snapshot != nil || nighthawk != nil {
                Picker("Tab", selection: $tab) {
                    ForEach(NHTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                Divider()

                switch tab {
                case .overview: overviewTab
                case .metrics:  metricsTab
                case .events:   eventsTab
                case .history:  ConnectorTimelineView(connectorId: "nighthawk")
                }
            } else {
                unavailableView
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.router")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Netgear Nighthawk")
                    .font(.headline)
                if let snap = snapshot {
                    Text(snap.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let error = connectorManager.connectorErrors["nighthawk"] {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text("Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let snap = snapshot {
                Text(snap.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                connectorManager.pollNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Refresh Nighthawk now")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Overview tab

    @ViewBuilder
    private var overviewTab: some View {
        if let snap = snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summaryTiles(snap)
                    ethPortSection(snap)
                    Spacer(minLength: 40)
                }
                .padding(20)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for Nighthawk data…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Summary tiles

    private func summaryTiles(_ snap: ConnectorSnapshot) -> some View {
        let m = snap.metrics
        func metric(_ key: String) -> ConnectorMetric? { m.first { $0.key == key } }

        let wanIP      = metric("wan_ip")?.unit ?? "–"
        let connType   = metric("conn_type")?.unit ?? ""
        let firmware   = metric("firmware")?.unit ?? ""
        let clients    = metric("client_count").map { Int($0.value) }
        let todayRX    = metric("today_rx_mb")?.value
        let todayTX    = metric("today_tx_mb")?.value
        let cpu        = metric("cpu_pct")?.value
        let mem        = metric("mem_pct")?.value
        let weekRX     = metric("week_rx_mb")?.value
        let fwUpdate   = metric("firmware_update")?.unit

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Router")
                    .font(.headline)
                if !firmware.isEmpty {
                    Text("FW \(firmware)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let upd = fwUpdate {
                    Label("Update \(upd)", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: 4),
                spacing: 12
            ) {
                NHTile(
                    icon: "network",
                    label: "WAN",
                    value: wanIP,
                    unit: connType.isEmpty ? "–" : connType,
                    color: wanIP == "–" ? .red : .green
                )
                NHTile(
                    icon: "laptopcomputer.and.iphone",
                    label: "Clients",
                    value: clients.map { "\($0)" } ?? "–",
                    unit: "connected",
                    color: .blue
                )
                NHTile(
                    icon: "arrow.down.circle",
                    label: "Today RX",
                    value: todayRX.map { mbString($0) } ?? "–",
                    unit: todayRX != nil ? "MB" : "",
                    color: .blue
                )
                NHTile(
                    icon: "arrow.up.circle",
                    label: "Today TX",
                    value: todayTX.map { mbString($0) } ?? "–",
                    unit: todayTX != nil ? "MB" : "",
                    color: .green
                )

                if let cpu {
                    NHTile(
                        icon: "cpu",
                        label: "CPU",
                        value: String(format: "%.0f", cpu),
                        unit: "%",
                        color: cpu > 90 ? .red : cpu > 70 ? .yellow : .green
                    )
                }
                if let mem {
                    NHTile(
                        icon: "memorychip",
                        label: "Memory",
                        value: String(format: "%.0f", mem),
                        unit: "%",
                        color: mem > 85 ? .red : mem > 70 ? .yellow : .green
                    )
                }
                if let weekRX {
                    NHTile(
                        icon: "calendar.circle",
                        label: "Week RX",
                        value: mbString(weekRX),
                        unit: "MB",
                        color: .secondary
                    )
                }
            }
        }
    }

    private func mbString(_ mb: Double) -> String {
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        return String(format: "%.0f", mb)
    }

    // MARK: - Ethernet port section

    private func ethPortSection(_ snap: ConnectorSnapshot) -> some View {
        let ports = snap.metrics.filter { $0.key.hasPrefix("eth_port_") }
        guard !ports.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(GroupBox("Ethernet Ports") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: min(ports.count, 4)),
                spacing: 8
            ) {
                ForEach(ports, id: \.key) { port in
                    let linked = port.value > 0
                    VStack(spacing: 4) {
                        Image(systemName: linked ? "cable.connector" : "cable.connector.slash")
                            .font(.title3)
                            .foregroundStyle(linked ? .green : Color(NSColor.tertiaryLabelColor))
                        Text(port.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(port.unit.isEmpty ? (linked ? "up" : "down") : port.unit)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(linked ? .green : .secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor)))
                }
            }
            .padding(.vertical, 4)
        })
    }

    // MARK: - Metrics tab

    @ViewBuilder
    private var metricsTab: some View {
        if let snap = snapshot, !snap.metrics.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible()), count: 3),
                        spacing: 10
                    ) {
                        ForEach(snap.metrics, id: \.key) { metric in
                            NHMetricCard(
                                metric: metric,
                                sparkline: connectorManager.snapshotStore
                                    .trend(for: "nighthawk", metricKey: metric.key, windowHours: 24)
                                    .sparkline
                            )
                        }
                    }
                    Spacer(minLength: 20)
                }
                .padding(20)
            }
        } else if snapshot != nil {
            Text("No metrics available")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Fetching metrics from Nighthawk…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Events tab

    @ViewBuilder
    private var eventsTab: some View {
        if let snap = snapshot, !snap.events.isEmpty {
            List {
                ForEach(Array(snap.events.prefix(30).enumerated()), id: \.offset) { _, event in
                    NHEventRow(event: event)
                }
            }
            .listStyle(.plain)
        } else {
            Text("No events recorded")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Unavailable

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.router")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Nighthawk connector not enabled")
            Text("Enable it in Preferences → Connectors.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Tile

private struct NHTile: View {
    let icon:  String
    let label: String
    let value: String
    let unit:  String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title2, design: .rounded).bold())
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        )
    }
}

// MARK: - Metric Card

private struct NHMetricCard: View {
    let metric:    ConnectorMetric
    let sparkline: [Double]

    var body: some View {
        VStack(spacing: 4) {
            Text(displayValue)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(severityColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(metric.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if sparkline.count >= 3 && metric.value != 0 {
                MiniSparkline(values: sparkline)
                    .frame(height: 16)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(NSColor.controlBackgroundColor))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1))
    }

    private var displayValue: String {
        if metric.value == 0 && !metric.unit.isEmpty &&
           !["Mbps", "%", "MB", "h", "ms", "dB", "dBmV", "active", ""].contains(metric.unit) {
            return metric.unit
        }
        let v = metric.value
        switch metric.unit {
        case "h":    return String(format: "%.0fh", v)
        case "Mbps": return String(format: "%.1f Mbps", v)
        case "%":    return String(format: "%.0f%%", v)
        case "MB":   return String(format: "%.0f MB", v)
        default:     return String(format: v < 10 && v != 0 ? "%.1f" : "%.0f", v)
        }
    }

    private var severityColor: Color {
        switch metric.severity {
        case .ok:       return .primary
        case .info:     return .blue
        case .warning:  return .yellow
        case .critical: return .red
        case .unknown:  return .secondary
        }
    }
}

// MARK: - Event Row

private struct NHEventRow: View {
    let event: ConnectorEvent

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(severityColor)
                .frame(width: 6, height: 6)
            Text(event.timestamp, style: .time)
                .font(.caption2).foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 60, alignment: .leading)
            Text(event.type.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(event.description)
                .font(.caption)
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var severityColor: Color {
        switch event.severity {
        case .ok, .info: return .blue
        case .warning:   return .yellow
        case .critical:  return .red
        case .unknown:   return .secondary
        }
    }
}
