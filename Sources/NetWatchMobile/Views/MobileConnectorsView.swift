/// MobileConnectorsView.swift — Full connector list with metrics and events

import SwiftUI

struct MobileConnectorsView: View {
    @EnvironmentObject var connection: ConnectionState

    var body: some View {
        NavigationStack {
            Group {
                if connection.connectors.isEmpty {
                    emptyState
                } else {
                    List(connection.connectors) { connector in
                        NavigationLink(destination: MobileConnectorDetail(connector: connector)) {
                            ConnectorRow(connector: connector)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Connectors")
            .refreshable { await connection.refresh() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(connection.mode.isConnected ? "No connectors" : connection.mode.label)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Connector Row

private struct ConnectorRow: View {
    let connector: APIConnectorPayload

    private var statusDot: Color {
        if !connector.connected      { return .red }
        if connector.criticalCount > 0 { return .red }
        if connector.warningCount  > 0 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusDot)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(connector.name)
                    .font(.headline)

                if let summary = connector.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let error = connector.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Metric count badge
            if connector.criticalCount > 0 {
                badge("\(connector.criticalCount) critical", color: .red)
            } else if connector.warningCount > 0 {
                badge("\(connector.warningCount) warn", color: .yellow)
            }
        }
        .padding(.vertical, 4)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Connector Detail

struct MobileConnectorDetail: View {
    let connector: APIConnectorPayload

    var body: some View {
        List {
            // Metrics
            if !connector.metrics.isEmpty {
                Section("Metrics") {
                    ForEach(connector.metrics) { metric in
                        MetricRow(metric: metric)
                    }
                }
            }

            // Events
            if !connector.events.isEmpty {
                Section("Recent Events") {
                    ForEach(connector.events.prefix(20)) { event in
                        EventRow(event: event)
                    }
                }
            }

            // Connection info
            Section("Connection") {
                LabeledContent("Status", value: connector.connected ? "Connected" : "Disconnected")
                if let updated = connector.lastUpdated {
                    LabeledContent("Last updated", value: updated)
                }
                if let error = connector.error {
                    LabeledContent("Error") {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
        }
        .navigationTitle(connector.name)
        .listStyle(.insetGrouped)
    }
}

// MARK: - Metric Row

private struct MetricRow: View {
    let metric: APIMetric

    private var valueColor: Color {
        switch metric.severity {
        case "critical": return .red
        case "warning":  return .yellow
        case "ok":       return .green
        default:         return .primary
        }
    }

    var body: some View {
        HStack {
            Image(systemName: metric.severityIcon)
                .foregroundStyle(valueColor)
                .frame(width: 20)

            Text(metric.label)
                .font(.subheadline)

            Spacer()

            Text(metric.formattedValue)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(valueColor)
        }
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: APIEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(event.type.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(event.timeAgoString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(event.description)
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
    }
}
