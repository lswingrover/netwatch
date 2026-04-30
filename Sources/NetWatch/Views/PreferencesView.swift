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

            ConnectorsTab(settings: $settings)
                .tabItem { Label("Connectors", systemImage: "cable.connector.horizontal") }

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
                    ForEach(Array(settings.pingTargets.enumerated()), id: \.element.id) { idx, _ in
                        HStack {
                            TextField("Host", text: $settings.pingTargets[idx].host)
                                .font(.system(.body, design: .monospaced))
                            TextField("Label (optional)", text: Binding(
                                get: { settings.pingTargets[idx].label ?? "" },
                                set: { settings.pingTargets[idx].label = $0.isEmpty ? nil : $0 }
                            ))
                            .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                settings.pingTargets.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this ping target")
                        }
                    }
                    .onMove { settings.pingTargets.move(fromOffsets: $0, toOffset: $1) }
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
                    ForEach(Array(settings.dnsTargets.enumerated()), id: \.element.id) { idx, _ in
                        HStack {
                            TextField("Domain", text: $settings.dnsTargets[idx].domain)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) {
                                settings.dnsTargets.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this DNS domain")
                        }
                    }
                    .onMove { settings.dnsTargets.move(fromOffsets: $0, toOffset: $1) }
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
                    ForEach(Array(settings.tracerouteTargets.enumerated()), id: \.element) { idx, _ in
                        HStack {
                            TextField("Host / IP", text: $settings.tracerouteTargets[idx])
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) {
                                settings.tracerouteTargets.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this traceroute target")
                        }
                    }
                    .onMove { settings.tracerouteTargets.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 60, maxHeight: 120)

                HStack {
                    TextField("Add host / IP", text: $newTracerouteTarget)
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

// MARK: - Connectors Tab

/// Configuration panel for device connectors. Each registered connector gets a
/// section with an enable toggle, connection fields, and a "Test Connection" button.
/// Settings are saved back to `MonitorSettings.connectorConfigs` on Apply.
struct ConnectorsTab: View {
    @Binding var settings: MonitorSettings

    private var descriptors: [ConnectorDescriptor] {
        ConnectorRegistry.shared.allDescriptors
    }

    var body: some View {
        if descriptors.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No connectors registered")
                    .font(.headline)
                Text("Connectors are registered at app launch. Built-in connectors\n(Firewalla, Nighthawk) appear here automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(descriptors) { desc in
                        ConnectorConfigSection(
                            descriptor: desc,
                            config: Binding(
                                get: { settings.connectorConfig(for: desc.id) },
                                set: { settings.setConnectorConfig($0) }
                            )
                        )
                        Divider()
                    }
                }
            }
        }
    }
}

/// A single connector's configuration row inside ConnectorsTab.
private struct ConnectorConfigSection: View {
    let descriptor: ConnectorDescriptor
    @Binding var config: ConnectorConfig

    @State private var testResult: String? = nil
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row — icon + name + enable toggle
            HStack(spacing: 10) {
                Image(systemName: descriptor.iconName)
                    .font(.title3)
                    .foregroundStyle(config.enabled ? .blue : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(descriptor.displayName).font(.headline)
                    Text(descriptor.description)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Toggle("", isOn: $config.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Config fields (only when enabled)
            if config.enabled {
                Divider().padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 8) {
                    // Host
                    LabeledContent(descriptor.configHelp.hostHelp.isEmpty ? "Host / IP" : descriptor.configHelp.hostHelp) {
                        TextField(descriptor.configHelp.hostPlaceholder, text: $config.host)
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 180)
                    }

                    // Port (show only if non-standard)
                    LabeledContent("Port (0 = default)") {
                        TextField("0", value: $config.port, format: .number)
                            .frame(width: 70)
                    }

                    // API Key / Token
                    if !descriptor.configHelp.apiKeyLabel.isEmpty {
                        LabeledContent(descriptor.configHelp.apiKeyLabel) {
                            SecureField(descriptor.configHelp.apiKeyHelp, text: $config.apiKey)
                                .frame(minWidth: 180)
                        }
                    }

                    // Username + Password (for SOAP/basic-auth connectors)
                    if descriptor.configHelp.showCredentials {
                        LabeledContent(descriptor.configHelp.usernameLabel.isEmpty ? "Username" : descriptor.configHelp.usernameLabel) {
                            TextField("admin", text: $config.username)
                                .frame(minWidth: 180)
                        }
                        LabeledContent(descriptor.configHelp.passwordLabel.isEmpty ? "Password" : descriptor.configHelp.passwordLabel) {
                            SecureField("router admin password", text: $config.password)
                                .frame(minWidth: 180)
                        }
                    }

                    // Test Connection button + result
                    HStack(spacing: 10) {
                        Button {
                            testConnection()
                        } label: {
                            if isTesting {
                                ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                            }
                            Text(isTesting ? "Testing…" : "Test Connection")
                        }
                        .disabled(isTesting || config.host.isEmpty)

                        if let result = testResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.red)
                                .lineLimit(2)
                        }

                        Spacer()

                        if let url = descriptor.docsURL, let link = URL(string: url) {
                            Link("Setup guide →", destination: link)
                                .font(.caption)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let cfg = config
        Task {
            // Instantiate a temporary connector to test — doesn't affect live polling
            if let connector = ConnectorRegistry.shared.make(descriptor.id, config: cfg) {
                let result = await connector.testConnection()
                await MainActor.run {
                    switch result {
                    case .success(let msg): testResult = "✓ \(msg)"
                    case .failure(let err): testResult = "✗ \(err.localizedDescription)"
                    }
                    isTesting = false
                }
            } else {
                await MainActor.run {
                    testResult = "✗ Connector not registered"
                    isTesting = false
                }
            }
        }
    }
}

// MARK: - Thresholds Tab

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
