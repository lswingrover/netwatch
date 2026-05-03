/// OrbiIntelligenceView.swift — Rich Netgear Orbi mesh panel
///
/// Tabs:
///   Overview  — Router summary tiles (WAN, clients, traffic) + satellite node list
///   Metrics   — Full ConnectorSnapshot metric grid with sparklines (mirrors ConnectorDetailView)
///   Events    — Connector event list
///   History   — ConnectorTimelineView trend chart
///
/// Accesses OrbiConnector by casting from ConnectorManager.

import SwiftUI

struct OrbiIntelligenceView: View {
    @EnvironmentObject var connectorManager: ConnectorManager

    private var orbi: OrbiConnector? {
        connectorManager.connectors.first(where: { $0.id == "orbi" }) as? OrbiConnector
    }

    private var snapshot: ConnectorSnapshot? {
        connectorManager.snapshot(for: "orbi")
    }

    @State private var tab: OrbiTab = .overview

    enum OrbiTab: String, CaseIterable {
        case overview = "Overview"
        case metrics  = "Metrics"
        case events   = "Events"
        case history  = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────────
            headerBar

            Divider()

            if snapshot != nil || orbi != nil {
                // Tab picker
                Picker("Tab", selection: $tab) {
                    ForEach(OrbiTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                Divider()

                // Tab content
                switch tab {
                case .overview: overviewTab
                case .metrics:  metricsTab
                case .events:   eventsTab
                case .history:  ConnectorTimelineView(connectorId: "orbi")
                }
            } else {
                unavailableView
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.router.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Netgear Orbi")
                    .font(.headline)
                if let snap = snapshot {
                    Text(snap.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .help("Refresh Orbi now")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Overview tab

    @ViewBuilder
    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let orbi {
                    routerSummaryTiles(orbi.lastRouterSummary)
                    satelliteSection(orbi)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for Orbi data…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer(minLength: 40)
            }
            .padding(20)
        }
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
                            OrbiMetricCard(
                                metric: metric,
                                sparkline: connectorManager.snapshotStore
                                    .trend(for: "orbi", metricKey: metric.key, windowHours: 24)
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
                Text("Fetching metrics from Orbi…")
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
                    OrbiEventRow(event: event)
                }
            }
            .listStyle(.plain)
        } else {
            Text("No events recorded")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Router summary tiles

    private func routerSummaryTiles(_ s: OrbiRouterSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Router")
                    .font(.headline)
                if !s.firmware.isEmpty {
                    Text("FW \(s.firmware)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !s.firmwareUpdate.isEmpty {
                    Label("Update \(s.firmwareUpdate)", systemImage: "arrow.down.circle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: 4),
                spacing: 12
            ) {
                OrbiTile(
                    icon:  "network",
                    label: "WAN",
                    value: s.wanIP.isEmpty ? "–" : s.wanIP,
                    unit:  s.wanStatus,
                    color: s.wanConnected ? .green : .red
                )
                OrbiTile(
                    icon:  "laptopcomputer.and.iphone",
                    label: "Clients",
                    value: "\(s.totalClients)",
                    unit:  "connected",
                    color: .blue
                )
                OrbiTile(
                    icon:  "arrow.down.circle",
                    label: "Today RX",
                    value: s.todayRXmb.map { mbString($0) } ?? "–",
                    unit:  s.todayRXmb != nil ? "MB" : "",
                    color: .blue
                )
                OrbiTile(
                    icon:  "arrow.up.circle",
                    label: "Today TX",
                    value: s.todayTXmb.map { mbString($0) } ?? "–",
                    unit:  s.todayTXmb != nil ? "MB" : "",
                    color: .green
                )

                if let cpu = s.cpuPct {
                    OrbiTile(
                        icon:  "cpu",
                        label: "CPU",
                        value: String(format: "%.0f", cpu),
                        unit:  "%",
                        color: cpu > 90 ? .red : cpu > 70 ? .yellow : .green
                    )
                }
                if let mem = s.memPct {
                    OrbiTile(
                        icon:  "memorychip",
                        label: "Memory",
                        value: String(format: "%.0f", mem),
                        unit:  "%",
                        color: mem > 85 ? .red : mem > 70 ? .yellow : .green
                    )
                }
                if let weekRX = s.weekRXmb {
                    OrbiTile(
                        icon:  "calendar.circle",
                        label: "Week RX",
                        value: mbString(weekRX),
                        unit:  "MB",
                        color: .secondary
                    )
                }
                OrbiTile(
                    icon:  s.guestEnabled ? "person.2.wave.2.fill" : "person.2.slash",
                    label: "Guest",
                    value: s.guestEnabled ? "ON" : "OFF",
                    unit:  "",
                    color: s.guestEnabled ? .orange : Color(NSColor.secondaryLabelColor)
                )
            }
        }
    }

    private func mbString(_ mb: Double) -> String {
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        return String(format: "%.0f", mb)
    }

    // MARK: - Satellite section

    private func satelliteSection(_ orbi: OrbiConnector) -> some View {
        GroupBox {
            if orbi.lastSatellites.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("No satellite nodes detected")
                            .foregroundStyle(.secondary)
                        Text("Satellites appear here once they report in via GetAttachDevice2. If your Orbi has satellites that aren't showing up, try running a manual poll.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
            } else {
                VStack(spacing: 0) {
                    // Column headers
                    HStack(spacing: 0) {
                        Text("").frame(width: 10)
                        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("IP").frame(width: 120, alignment: .trailing)
                        Text("Backhaul").frame(width: 90, alignment: .trailing)
                        Text("Clients").frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)

                    Divider()

                    ForEach(orbi.lastSatellites) { sat in
                        SatelliteRow(satellite: sat)
                        Divider().padding(.horizontal, 8)
                    }
                }
            }
        } label: {
            HStack {
                Text("Satellite Nodes")
                Spacer()
                Text("\(orbi.lastSatellites.count) detected")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Unavailable

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.router.fill")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Orbi connector not enabled")
            Text("Enable it in Preferences → Connectors.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Satellite Row

private struct SatelliteRow: View {
    let satellite: OrbiSatellite

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(satellite.isOnline ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(satellite.name).font(.callout)
                Text(satellite.mac)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(satellite.ip.isEmpty ? "–" : satellite.ip)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)

            HStack(spacing: 4) {
                Image(systemName: satellite.backhaulIcon)
                    .font(.caption)
                    .foregroundStyle(backhaulColor(satellite))
                Text(satellite.backhaulLabel)
                    .font(.caption)
                    .foregroundStyle(backhaulColor(satellite))
            }
            .frame(width: 90, alignment: .trailing)

            Text(satellite.clientCount == 0 ? "–" : "\(satellite.clientCount)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func backhaulColor(_ sat: OrbiSatellite) -> Color {
        switch sat.backhaulBand {
        case "6":   return .purple
        case "5":   return .blue
        case "eth", "wired": return .green
        default:    return .secondary
        }
    }
}

// MARK: - Metric Card

private struct OrbiMetricCard: View {
    let metric:    ConnectorMetric
    let sparkline: [Double]

    init(metric: ConnectorMetric, sparkline: [Double] = []) {
        self.metric    = metric
        self.sparkline = sparkline
    }

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
        case "h":     return String(format: "%.0fh", v)
        case "Mbps":  return String(format: "%.1f Mbps", v)
        case "%":     return String(format: "%.0f%%", v)
        case "MB":    return String(format: "%.0f MB", v)
        case "dB":    return String(format: "%.1f dB", v)
        case "dBmV":  return String(format: "%.1f dBmV", v)
        default:      return String(format: v < 10 && v != 0 ? "%.1f" : "%.0f", v)
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

private struct OrbiEventRow: View {
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

// MARK: - OrbiTile

private struct OrbiTile: View {
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
