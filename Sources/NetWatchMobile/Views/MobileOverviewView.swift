/// MobileOverviewView.swift — Main dashboard: health score ring, connection banner,
/// connector status tiles, and last-updated timestamp.

import SwiftUI

struct MobileOverviewView: View {
    @EnvironmentObject var connection: ConnectionState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    // ── Connection/Away Mode Banner ────────────────────────────
                    ConnectionBanner()

                    // ── Health Score Ring ──────────────────────────────────────
                    if let health = connection.health {
                        HealthScoreRing(health: health)
                    } else {
                        HealthRingPlaceholder()
                    }

                    // ── Connector Tiles ────────────────────────────────────────
                    if connection.connectors.isEmpty {
                        ConnectorPlaceholder()
                    } else {
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            ForEach(connection.connectors) { connector in
                                NavigationLink(destination: MobileConnectorDetail(connector: connector)) {
                                    ConnectorTile(connector: connector)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // ── Recent Incidents Summary ───────────────────────────────
                    if !connection.incidents.isEmpty {
                        RecentIncidentsSummary(incidents: connection.incidents)
                    }

                    // ── Last Updated ───────────────────────────────────────────
                    if let updated = connection.lastUpdated {
                        Text("Updated \(updated, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("NetWatch")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await connection.refresh() }
                    } label: {
                        if connection.isRefreshing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(connection.isRefreshing)
                }
            }
            .refreshable {
                await connection.refresh()
            }
        }
    }
}

// MARK: - Connection Banner

private struct ConnectionBanner: View {
    @EnvironmentObject var connection: ConnectionState

    @ViewBuilder
    var body: some View {
        switch connection.mode {
        case .unconfigured:
            banner(icon: "wifi.slash",
                   text: "Configure Mac IP in Settings to connect.",
                   color: .secondary)
        case .connecting:
            banner(icon: "arrow.clockwise",
                   text: "Connecting to Mac…",
                   color: .secondary)
        case .connected:
            EmptyView()  // Home network — no banner needed
        case .away:
            banner(icon: "arrow.triangle.2.circlepath",
                   text: "Away Mode — connected via WireGuard VPN",
                   color: .blue)
        case .error(let msg):
            banner(icon: "exclamationmark.triangle.fill",
                   text: "Offline: \(msg)",
                   color: .red)
        }
    }

    private func banner(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
}

// MARK: - Health Score Ring

private struct HealthScoreRing: View {
    let health: APIHealthPayload

    private var ringColor: Color {
        switch health.statusColor {
        case .green:  return .green
        case .yellow: return .yellow
        case .red:    return .red
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(ringColor.opacity(0.2), lineWidth: 16)
                    .frame(width: 160, height: 160)

                Circle()
                    .trim(from: 0, to: CGFloat(health.score) / 100)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 160, height: 160)
                    .animation(.easeOut(duration: 0.8), value: health.score)

                VStack(spacing: 4) {
                    Text("\(health.score)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(ringColor)
                    Text(health.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Mac status line
            if let status = connectionStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    @EnvironmentObject private var connection: ConnectionState

    private var connectionStatus: String? {
        guard let s = connection.status else { return nil }
        var parts: [String] = []
        if !s.wifiSSID.isEmpty   { parts.append("📶 \(s.wifiSSID)") }
        if !s.macLocalIP.isEmpty { parts.append(s.macLocalIP) }
        if let rtt = s.gatewayRTT { parts.append("\(String(format: "%.1f", rtt))ms gateway") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Placeholders

private struct HealthRingPlaceholder: View {
    @EnvironmentObject var connection: ConnectionState

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 16)
                .frame(width: 160, height: 160)
            VStack(spacing: 6) {
                if connection.mode == .connecting {
                    ProgressView()
                } else {
                    Image(systemName: "wifi.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
                Text(connection.mode.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}

private struct ConnectorPlaceholder: View {
    @EnvironmentObject var connection: ConnectionState

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cable.connector.horizontal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(connection.mode.isConnected ? "No connectors available" : "Waiting for connection…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

// MARK: - Connector Tile

private struct ConnectorTile: View {
    let connector: APIConnectorPayload

    private var statusColor: Color {
        if !connector.connected { return .red }
        if connector.criticalCount > 0 { return .red }
        if connector.warningCount > 0  { return .yellow }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Spacer()
                if connector.criticalCount > 0 {
                    Text("\(connector.criticalCount)!")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
            }

            Text(connector.name)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let summary = connector.summary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Top 2 metrics
            ForEach(connector.metrics.prefix(2)) { metric in
                HStack {
                    Text(metric.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(metric.formattedValue)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(metric.severity == "critical" ? .red :
                                         metric.severity == "warning"  ? .yellow : .primary)
                }
            }
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(statusColor.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Recent Incidents Summary

private struct RecentIncidentsSummary: View {
    let incidents: [APIIncidentSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Incidents")
                .font(.headline)
                .padding(.horizontal)

            ForEach(incidents.prefix(3)) { incident in
                HStack(spacing: 12) {
                    Image(systemName: incident.severityIcon)
                        .foregroundStyle(.orange)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(incident.rootCause)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(incident.timeAgoString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
            }
        }
    }
}
