/// ConnectorsView.swift — Device connector panel for NetWatch
///
/// Shows all registered connectors in a sidebar list. Selecting one displays its
/// live metrics, recent events, and connection status in the detail panel.
/// Connectors are configured in Settings → Connectors.
///
/// Architecture note: ConnectorsView reads from ConnectorManager (injected via
/// EnvironmentObject). ConnectorManager is owned by NetworkMonitorService and
/// polled independently of the ping/DNS loop.

import SwiftUI

struct ConnectorsView: View {
    @EnvironmentObject var connectorManager: ConnectorManager
    @EnvironmentObject var monitor: NetworkMonitorService
    @State private var selectedID: String? = nil

    var descriptors: [ConnectorDescriptor] {
        ConnectorRegistry.shared.allDescriptors
    }

    var body: some View {
        HSplitView {
            // Left: connector list
            VStack(spacing: 0) {
                List(descriptors, selection: $selectedID) { desc in
                    ConnectorListRow(
                        descriptor: desc,
                        config: monitor.settings.connectorConfigs.first { $0.id == desc.id },
                        snapshot: connectorManager.snapshot(for: desc.id)
                    )
                    .tag(desc.id)
                }
                .listStyle(.sidebar)

                // Footer: polling indicator
                Divider()
                HStack(spacing: 6) {
                    if connectorManager.isPolling {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                        Text("Polling…").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("30s poll cycle").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        connectorManager.pollNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh all connectors now")
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            // Right: detail
            if let id = selectedID, let desc = descriptors.first(where: { $0.id == id }) {
                ConnectorDetailView(
                    descriptor: desc,
                    config: monitor.settings.connectorConfigs.first { $0.id == id },
                    snapshot: connectorManager.snapshot(for: id)
                )
                .id(id)
            } else {
                ConnectorEmptyState()
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = descriptors.first?.id }
        }
    }
}

// MARK: - List Row

private struct ConnectorListRow: View {
    let descriptor: ConnectorDescriptor
    let config:     ConnectorConfig?
    let snapshot:   ConnectorSnapshot?

    private var isEnabled: Bool   { config?.enabled ?? false }
    private var hasData:   Bool   { snapshot != nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: descriptor.iconName)
                .frame(width: 18)
                .foregroundStyle(isEnabled ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName).font(.body).lineLimit(1)
                Text(statusLine)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
        }
    }

    private var statusLine: String {
        guard isEnabled else { return "Disabled" }
        guard let snap = snapshot else { return "Connecting…" }
        return snap.summary
    }

    private var statusColor: Color {
        guard isEnabled  else { return .secondary }
        guard hasData    else { return .yellow }
        let hasCritical = snapshot?.events.contains { $0.severity == .critical } ?? false
        let hasWarning  = snapshot?.metrics.contains { $0.severity == .warning || $0.severity == .critical } ?? false
        if hasCritical { return .red }
        if hasWarning  { return .yellow }
        return .green
    }
}

// MARK: - Detail View

private struct ConnectorDetailView: View {
    let descriptor: ConnectorDescriptor
    let config:     ConnectorConfig?
    let snapshot:   ConnectorSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: descriptor.iconName)
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.displayName).font(.headline)
                        Text(descriptor.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let snap = snapshot {
                        Text(snap.timestamp, style: .time)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if let config, config.enabled {
                    if let snapshot {
                        // Metrics grid
                        if !snapshot.metrics.isEmpty {
                            GroupBox("Metrics") {
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible()), count: 3),
                                    spacing: 10
                                ) {
                                    ForEach(snapshot.metrics, id: \.key) { metric in
                                        ConnectorMetricCard(metric: metric)
                                    }
                                }
                            }
                        }

                        // Events
                        if !snapshot.events.isEmpty {
                            GroupBox("Recent Events") {
                                VStack(spacing: 0) {
                                    ForEach(Array(snapshot.events.prefix(10).enumerated()),
                                            id: \.offset) { _, event in
                                        ConnectorEventRow(event: event)
                                        Divider().opacity(0.4)
                                    }
                                }
                            }
                        } else {
                            GroupBox("Recent Events") {
                                Text("No events")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                            }
                        }

                    } else {
                        // Enabled but no data yet
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Fetching data from \(config.host.isEmpty ? "device" : config.host)…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // Not enabled
                    ConnectorSetupPrompt(descriptor: descriptor)
                }

                Spacer()
            }
            .padding(20)
        }
        .navigationTitle(descriptor.displayName)
    }
}

// MARK: - Metric Card

private struct ConnectorMetricCard: View {
    let metric: ConnectorMetric

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
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var displayValue: String {
        // For string-value metrics (unit = the value), just show the unit
        if metric.value == 0 && !metric.unit.isEmpty && !["Mbps", "%", "MB", "h", "ms", ""].contains(metric.unit) {
            return metric.unit
        }
        let v = metric.value
        switch metric.unit {
        case "h":    return String(format: "%.0fh", v)
        case "Mbps": return String(format: "%.1f Mbps", v)
        case "%":    return String(format: "%.0f%%", v)
        case "MB":   return String(format: "%.0f MB", v)
        default:     return String(format: "%.0f", v)
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

private struct ConnectorEventRow: View {
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

// MARK: - Setup Prompt

private struct ConnectorSetupPrompt: View {
    let descriptor: ConnectorDescriptor

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: descriptor.iconName)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Connect your \(descriptor.displayName)")
                .font(.headline)
            Text(descriptor.description)
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Text("Open **Settings → Connectors** to enter your device's IP address and credentials, then enable the connector.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let url = descriptor.docsURL {
                Link("Setup guide →", destination: URL(string: url)!)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Empty State

private struct ConnectorEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No connector selected")
                .foregroundStyle(.secondary)
            Text("Select a device from the list to see live data.\nConfigure connectors in Settings → Connectors.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
