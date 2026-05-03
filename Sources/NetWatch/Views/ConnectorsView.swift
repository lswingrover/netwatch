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

/// Sentinel connector ID for the Stack Health panel.
private let stackHealthID = "__stack_health__"

struct ConnectorsView: View {
    @EnvironmentObject var connectorManager: ConnectorManager
    @EnvironmentObject var monitor: NetworkMonitorService
    @State private var selectedID: String? = nil

    /// Deep-link binding set by topology node taps. ConnectorsView consumes and clears it.
    var requestedConnectorID: Binding<String?> = .constant(nil)

    var descriptors: [ConnectorDescriptor] {
        ConnectorRegistry.shared.allDescriptors
    }

    var body: some View {
        HSplitView {
            // Left: connector list
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    // ── Stack Health (always first) ──────────────────────────
                    Section {
                        StackHealthListRow()
                            .tag(stackHealthID)
                    }
                    // ── Device connectors ────────────────────────────────────
                    Section("Devices") {
                        ForEach(descriptors) { desc in
                            ConnectorListRow(
                                descriptor: desc,
                                config: monitor.settings.connectorConfigs.first { $0.id == desc.id },
                                snapshot: connectorManager.snapshot(for: desc.id),
                                errorMessage: connectorManager.connectorErrors[desc.id]
                            )
                            .tag(desc.id)
                        }
                    }
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
            if selectedID == stackHealthID {
                StackHealthView()
                    .id(stackHealthID)
            } else if selectedID == "firewalla" {
                FirewallaIntelligenceView()
                    .id("firewalla")
            } else if selectedID == "orbi" {
                OrbiIntelligenceView()
                    .id("orbi")
            } else if selectedID == "nighthawk" {
                NighthawkIntelligenceView()
                    .id("nighthawk")
            } else if let id = selectedID, let desc = descriptors.first(where: { $0.id == id }) {
                ConnectorDetailView(
                    descriptor: desc,
                    config: monitor.settings.connectorConfigs.first { $0.id == id },
                    snapshot: connectorManager.snapshot(for: id),
                    connectorId: id
                )
                .id(id)
            } else {
                ConnectorEmptyState()
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = stackHealthID }
        }
        .onChange(of: requestedConnectorID.wrappedValue) { _, newID in
            if let id = newID {
                selectedID = id
                requestedConnectorID.wrappedValue = nil
            }
        }
    }
}

// MARK: - Stack Health List Row

private struct StackHealthListRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stethoscope")
                .frame(width: 18)
                .foregroundStyle(.purple)
            Text("Stack Health")
                .font(.body)
            Spacer()
        }
    }
}

// MARK: - List Row

private struct ConnectorListRow: View {
    let descriptor: ConnectorDescriptor
    let config:     ConnectorConfig?
    let snapshot:   ConnectorSnapshot?
    var errorMessage: String? = nil   // from ConnectorManager.connectorErrors

    private var isEnabled: Bool   { config?.enabled ?? false }
    private var hasData:   Bool   { snapshot != nil }
    private var hasError:  Bool   { errorMessage != nil && snapshot == nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: descriptor.iconName)
                .frame(width: 18)
                .foregroundStyle(isEnabled ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName).font(.body).lineLimit(1)
                Text(statusLine)
                    .font(.caption).foregroundStyle(hasError ? .red : .secondary).lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
        }
    }

    private var statusLine: String {
        guard isEnabled else { return "Disabled" }
        if let snap = snapshot { return snap.summary }
        if let err = errorMessage { return "Error: \(err)" }
        return "Connecting…"
    }

    private var statusColor: Color {
        guard isEnabled  else { return .secondary }
        if hasError      { return .red }
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
    let descriptor:  ConnectorDescriptor
    let config:      ConnectorConfig?
    let snapshot:    ConnectorSnapshot?
    let connectorId: String

    @EnvironmentObject var connectorManager: ConnectorManager
    @State private var tab: DetailTab = .metrics

    enum DetailTab: String, CaseIterable {
        case metrics = "Metrics"
        case events  = "Events"
        case history = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: descriptor.iconName)
                    .font(.title2).foregroundStyle(.blue)
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
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if let config, config.enabled {
                // Tab picker
                Picker("Tab", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                Divider()

                // Tab content
                switch tab {
                case .metrics:
                    metricsTab
                case .events:
                    eventsTab
                case .history:
                    ConnectorTimelineView(connectorId: connectorId)
                }
            } else {
                ConnectorSetupPrompt(descriptor: descriptor)
            }
        }
        .navigationTitle(descriptor.displayName)
    }

    // MARK: - Metrics tab

    @ViewBuilder
    private var metricsTab: some View {
        if let snapshot, !snapshot.metrics.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible()), count: 3),
                        spacing: 10
                    ) {
                        ForEach(snapshot.metrics, id: \.key) { metric in
                            ConnectorMetricCard(
                                metric: metric,
                                sparkline: connectorManager.snapshotStore
                                    .trend(for: connectorId, metricKey: metric.key, windowHours: 24)
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
                Text("Fetching data from \(config?.host.isEmpty == false ? config!.host : "device")…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Events tab

    @ViewBuilder
    private var eventsTab: some View {
        if let snapshot, !snapshot.events.isEmpty {
            List {
                ForEach(Array(snapshot.events.prefix(30).enumerated()), id: \.offset) { _, event in
                    ConnectorEventRow(event: event)
                }
            }
            .listStyle(.plain)
        } else {
            Text("No events recorded")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Metric Card

private struct ConnectorMetricCard: View {
    let metric:    ConnectorMetric
    let sparkline: [Double]    ///< normalised 0–1 from SnapshotStore; may be empty

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
            // Sparkline (shown only when history is available and metric is numeric)
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
        // For string-value metrics (unit = the value), just show the unit
        if metric.value == 0 && !metric.unit.isEmpty && !["Mbps", "%", "MB", "h", "ms", "dB", "dBmV", "active", ""].contains(metric.unit) {
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
