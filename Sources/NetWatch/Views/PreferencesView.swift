import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @EnvironmentObject var monitor: NetworkMonitorService
    @State private var settings: MonitorSettings = .default
    @State private var newPingHost: String = ""
    @State private var newDNSDomain: String = ""
    @State private var newTracerouteTarget: String = ""

    var body: some View {
        TabView {
            TargetsTab(settings: $settings, newPingHost: $newPingHost,
                       newDNSDomain: $newDNSDomain, newTracerouteTarget: $newTracerouteTarget)
                .tabItem { Label("Targets", systemImage: "antenna.radiowaves.left.and.right") }

            ThresholdsTab(settings: $settings)
                .tabItem { Label("Thresholds", systemImage: "slider.horizontal.3") }

            StorageTab(settings: $settings)
                .tabItem { Label("Storage", systemImage: "folder") }
        }
        .onAppear { settings = monitor.settings }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel") { settings = monitor.settings }
                Button("Apply & Restart") {
                    monitor.settings = settings
                    monitor.restart()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

struct TargetsTab: View {
    @Binding var settings: MonitorSettings
    @Binding var newPingHost: String
    @Binding var newDNSDomain: String
    @Binding var newTracerouteTarget: String

    var body: some View {
        Form {
            Section("Ping Targets") {
                List {
                    ForEach($settings.pingTargets) { $target in
                        HStack {
                            TextField("Host", text: $target.host)
                                .font(.system(.body, design: .monospaced))
                            TextField("Label (optional)", text: Binding(
                                get: { target.label ?? "" },
                                set: { target.label = $0.isEmpty ? nil : $0 }
                            ))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { settings.pingTargets.remove(atOffsets: $0) }
                    .onMove  { settings.pingTargets.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 100, maxHeight: 200)

                HStack {
                    TextField("Add host (e.g. 1.1.1.1)", text: $newPingHost)
                        .onSubmit { addPingHost() }
                    Button("Add", action: addPingHost)
                        .disabled(newPingHost.isEmpty)
                }
            }

            Section("DNS Domains") {
                List {
                    ForEach($settings.dnsTargets) { $target in
                        TextField("Domain", text: $target.domain)
                            .font(.system(.body, design: .monospaced))
                    }
                    .onDelete { settings.dnsTargets.remove(atOffsets: $0) }
                    .onMove  { settings.dnsTargets.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 100, maxHeight: 160)

                HStack {
                    TextField("Add domain", text: $newDNSDomain)
                        .onSubmit { addDNSDomain() }
                    Button("Add", action: addDNSDomain).disabled(newDNSDomain.isEmpty)
                }
            }

            Section("Traceroute Targets") {
                List {
                    ForEach(settings.tracerouteTargets, id: \.self) { target in
                        Text(target).font(.system(.body, design: .monospaced))
                    }
                    .onDelete { settings.tracerouteTargets.remove(atOffsets: $0) }
                }
                .frame(minHeight: 60, maxHeight: 100)

                HStack {
                    TextField("Add target", text: $newTracerouteTarget)
                        .onSubmit { addTracerouteTarget() }
                    Button("Add", action: addTracerouteTarget).disabled(newTracerouteTarget.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    func addPingHost() {
        let h = newPingHost.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        settings.pingTargets.append(PingTarget(host: h))
        newPingHost = ""
    }
    func addDNSDomain() {
        let d = newDNSDomain.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty else { return }
        settings.dnsTargets.append(DNSTarget(domain: d))
        newDNSDomain = ""
    }
    func addTracerouteTarget() {
        let t = newTracerouteTarget.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        settings.tracerouteTargets.append(t)
        newTracerouteTarget = ""
    }
}

struct ThresholdsTab: View {
    @Binding var settings: MonitorSettings

    var body: some View {
        Form {
            Section("Intervals") {
                LabeledContent("Ping interval") {
                    Stepper("\(String(format: "%.0f", settings.pingIntervalSeconds))s",
                            value: $settings.pingIntervalSeconds, in: 0.5...10, step: 0.5)
                }
                LabeledContent("DNS interval") {
                    Stepper("\(Int(settings.dnsIntervalSeconds))s",
                            value: $settings.dnsIntervalSeconds, in: 5...300, step: 5)
                }
                LabeledContent("Traceroute interval") {
                    Stepper("\(Int(settings.tracerouteIntervalSeconds))s",
                            value: $settings.tracerouteIntervalSeconds, in: 30...600, step: 30)
                }
            }

            Section("Incident Triggers") {
                LabeledContent("Ping fail threshold") {
                    Stepper("\(settings.pingFailThreshold) consecutive",
                            value: $settings.pingFailThreshold, in: 1...10)
                }
                LabeledContent("DNS fail threshold") {
                    Stepper("\(settings.dnsFailThreshold) consecutive",
                            value: $settings.dnsFailThreshold, in: 1...10)
                }
                LabeledContent("Incident cooldown") {
                    Stepper("\(Int(settings.incidentCooldownSeconds))s",
                            value: $settings.incidentCooldownSeconds, in: 30...600, step: 30)
                }
            }

            Section("Interface") {
                LabeledContent("Network interface") {
                    TextField("auto-detect", text: $settings.networkInterface)
                        .frame(width: 100)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct StorageTab: View {
    @Binding var settings: MonitorSettings

    var body: some View {
        Form {
            Section("Log Directory") {
                LabeledContent("Base path") {
                    TextField("~/network_tests", text: $settings.baseDirectory)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 220)
                }
                Text("Logs, incidents, and ping histories are stored here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                Button("Open Base Directory") {
                    let path = (settings.baseDirectory as NSString).expandingTildeInPath
                    let url  = URL(fileURLWithPath: path)
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
                Button("Reveal Incidents Folder") {
                    let path = (settings.baseDirectory as NSString).expandingTildeInPath
                    let url  = URL(fileURLWithPath: path).appendingPathComponent("incidents")
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
            }

            Section("Configuration") {
                Button("Export Settings…") { exportSettings() }
                Button("Import Settings…") { importSettings() }
                Text("Export/import all targets, thresholds, and paths as JSON.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "netwatch-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? pretty.write(to: url)
        } else {
            try? data.write(to: url)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let imported = try? JSONDecoder().decode(MonitorSettings.self, from: data)
        else { return }
        settings = imported
    }
}
