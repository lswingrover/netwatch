import SwiftUI

struct IncidentsView: View {
    @EnvironmentObject var incidentManager: IncidentManager
    @State private var selectedID: UUID? = nil

    var selected: Incident? {
        incidentManager.incidents.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            List(incidentManager.incidents, selection: $selectedID) { incident in
                IncidentRow(incident: incident).tag(incident.id)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 260, idealWidth: 300)
            .overlay {
                if incidentManager.incidents.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.largeTitle).foregroundStyle(.green)
                        Text("No incidents").foregroundStyle(.secondary)
                    }
                }
            }

            if let inc = selected {
                IncidentDetailView(incident: inc)
            } else {
                Text("Select an incident")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct IncidentRow: View {
    let incident: Incident
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                Text(incident.reason).font(.callout).lineLimit(1)
            }
            Text(incident.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(incident.formattedDate).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

struct IncidentDetailView: View {
    let incident: Incident
    @State private var incidentText: String = ""
    @State private var ticketText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(incident.reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.orange)
                        Text(incident.subject).font(.subheadline).foregroundStyle(.secondary)
                        Text(incident.formattedDate).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Open Bundle Folder") {
                        NSWorkspace.shared.open(incident.bundlePath)
                    }
                }

                Divider()

                if !incidentText.isEmpty {
                    GroupBox("Incident Report") {
                        ScrollView {
                            Text(incidentText)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 250)
                    }
                }

                if !ticketText.isEmpty {
                    GroupBox("ISP Tier-2 Ticket Draft") {
                        VStack(alignment: .leading, spacing: 8) {
                            ScrollView {
                                Text(ticketText)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)

                            Button("Copy to Clipboard") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ticketText, forType: .string)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                Spacer()
            }
            .padding(20)
        }
        .onAppear { loadFiles() }
        .onChange(of: incident.id) { loadFiles() }
    }

    private func loadFiles() {
        let incFile    = incident.bundlePath.appendingPathComponent("incident.txt")
        let ticketFile = incident.bundlePath.appendingPathComponent("tier2_ticket.txt")
        incidentText = (try? String(contentsOf: incFile)) ?? ""
        ticketText   = (try? String(contentsOf: ticketFile)) ?? ""
    }
}
