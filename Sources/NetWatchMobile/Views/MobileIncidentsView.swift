/// MobileIncidentsView.swift — Incident list sorted by date (most recent first)

import SwiftUI

struct MobileIncidentsView: View {
    @EnvironmentObject var connection: ConnectionState

    var body: some View {
        NavigationStack {
            Group {
                if connection.incidents.isEmpty {
                    emptyState
                } else {
                    List(connection.incidents) { incident in
                        IncidentRow(incident: incident)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Incidents")
            .refreshable { await connection.refresh() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("No incidents")
                .font(.headline)
            Text("NetWatch will log connectivity events here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Incident Row

private struct IncidentRow: View {
    let incident: APIIncidentSummary

    private var severityColor: Color {
        switch incident.severity {
        case "critical": return .red
        case "warning":  return .orange
        default:         return .blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: incident.severityIcon)
                .foregroundStyle(severityColor)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(incident.rootCause)
                    .font(.subheadline.bold())
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(incident.timeAgoString)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if incident.healthScore > 0 {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("Score: \(incident.healthScore)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}
