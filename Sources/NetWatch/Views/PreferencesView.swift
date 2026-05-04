import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @EnvironmentObject var monitor:       NetworkMonitorService
    @EnvironmentObject var updateChecker: UpdateChecker
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

            AlertingTab(settings: $settings)
                .tabItem { Label("Alerting", systemImage: "bell.badge") }

            AboutTab()
                .environmentObject(updateChecker)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .onAppear { settings = monitor.settings }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel") { settings = monitor.settings }
                Button("Apply & Restart") {
                    monitor.settings = settings
                    monitor.restart()
                    // Close the preferences window so the user can see the app restart
                    NSApp.keyWindow?.performClose(nil)
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

    @State private var showBulkImport = false

    var body: some View {
        Form {
            // ── Quick Cross-Add bar ────────────────────────────────────────────
            Section {
                CrossAddBar(settings: $settings)
            } header: {
                HStack {
                    Text("Quick Add")
                    Spacer()
                    Button {
                        showBulkImport = true
                    } label: {
                        Label("Bulk Import…", systemImage: "square.and.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            } footer: {
                Text("Quick Add lets you add one entry to multiple lists simultaneously. Use Bulk Import for pasting many at once.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
        .sheet(isPresented: $showBulkImport) {
            BulkImportSheet(settings: $settings)
        }
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

// MARK: - Cross-Add Bar

/// Lets the user type a single host/domain once and add it to multiple lists simultaneously.
private struct CrossAddBar: View {
    @Binding var settings: MonitorSettings
    @State private var text:          String = ""
    @State private var addToPing:     Bool   = true
    @State private var addToDNS:      Bool   = false
    @State private var addToTrace:    Bool   = false
    @State private var addedFeedback: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Host / IP / domain", text: $text)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { commit() }

                Toggle("Ping", isOn: $addToPing)
                    .toggleStyle(.checkbox)
                Toggle("DNS",  isOn: $addToDNS)
                    .toggleStyle(.checkbox)
                Toggle("Trace",isOn: $addToTrace)
                    .toggleStyle(.checkbox)

                Button("Add to Selected", action: commit)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || (!addToPing && !addToDNS && !addToTrace))
            }
            if !addedFeedback.isEmpty {
                Text(addedFeedback)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private func commit() {
        let entry = text.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return }
        var added: [String] = []
        if addToPing  {
            if !settings.pingTargets.contains(where: { $0.host == entry }) {
                settings.pingTargets.append(PingTarget(host: entry))
                added.append("Ping")
            }
        }
        if addToDNS   {
            if !settings.dnsTargets.contains(where: { $0.domain == entry }) {
                settings.dnsTargets.append(DNSTarget(domain: entry))
                added.append("DNS")
            }
        }
        if addToTrace {
            if !settings.tracerouteTargets.contains(entry) {
                settings.tracerouteTargets.append(entry)
                added.append("Trace")
            }
        }
        if added.isEmpty {
            addedFeedback = "\"\(entry)\" already present in selected lists."
        } else {
            addedFeedback = "Added \"\(entry)\" to: \(added.joined(separator: ", "))"
        }
        text = ""
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { addedFeedback = "" }
        }
    }
}

// MARK: - Bulk Import Sheet

/// Modal for pasting/importing many targets at once.
/// Supports plain-text lists (one entry per line) and simple CSV (host,label).
struct BulkImportSheet: View {
    @Binding var settings: MonitorSettings
    @Environment(\.dismiss) var dismiss

    @State private var rawText:    String = ""
    @State private var addToPing:  Bool   = true
    @State private var addToDNS:   Bool   = false
    @State private var addToTrace: Bool   = false
    @State private var preview:    [ParsedEntry] = []
    @State private var didImport   = false
    @State private var importCount = 0

    struct ParsedEntry: Identifiable {
        let id = UUID()
        let host: String
        let label: String
        var duplicate: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bulk Import Targets")
                        .font(.headline)
                    Text("Paste one host or IP per line. CSV format: host,label")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            HStack(alignment: .top, spacing: 16) {
                // Left: text editor
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste targets:")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $rawText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor)))
                        .onChange(of: rawText) { _, _ in updatePreview() }

                    // Destination picker
                    HStack(spacing: 16) {
                        Text("Add to:").font(.caption).foregroundStyle(.secondary)
                        Toggle("Ping",  isOn: $addToPing) .toggleStyle(.checkbox)
                        Toggle("DNS",   isOn: $addToDNS)  .toggleStyle(.checkbox)
                        Toggle("Trace", isOn: $addToTrace).toggleStyle(.checkbox)
                    }
                    .onChange(of: addToPing)  { _, _ in updatePreview() }
                    .onChange(of: addToDNS)   { _, _ in updatePreview() }
                    .onChange(of: addToTrace) { _, _ in updatePreview() }
                }

                // Right: live preview
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Preview (\(preview.count) entries):")
                            .font(.caption).foregroundStyle(.secondary)
                        if preview.contains(where: { $0.duplicate }) {
                            Text("· some already exist")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    List {
                        ForEach(preview) { entry in
                            HStack(spacing: 6) {
                                Image(systemName: entry.duplicate ? "minus.circle" : "plus.circle")
                                    .foregroundStyle(entry.duplicate
                                        ? Color(NSColor.tertiaryLabelColor)
                                        : Color.green)
                                    .font(.system(size: 11))
                                Text(entry.host)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(entry.duplicate ? .secondary : .primary)
                                if !entry.label.isEmpty {
                                    Text(entry.label)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor)))
                }
            }
            .padding(20)

            Divider()

            // Footer
            HStack {
                if didImport {
                    Label("Imported \(importCount) entries", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import \(preview.filter { !$0.duplicate }.count) New Entries") {
                    doImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(preview.filter { !$0.duplicate }.isEmpty || (!addToPing && !addToDNS && !addToTrace))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 680, height: 440)
    }

    private func updatePreview() {
        let lines = rawText.components(separatedBy: .newlines)
        preview = lines.compactMap { line -> ParsedEntry? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.components(separatedBy: ",")
            let host  = parts[0].trimmingCharacters(in: .whitespaces)
            let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            guard !host.isEmpty else { return nil }

            // Check for duplicates across selected lists
            let existsPing  = addToPing  && settings.pingTargets.contains(where: { $0.host == host })
            let existsDNS   = addToDNS   && settings.dnsTargets.contains(where: { $0.domain == host })
            let existsTrace = addToTrace && settings.tracerouteTargets.contains(host)
            let allSelected = (!addToPing || existsPing) && (!addToDNS || existsDNS) && (!addToTrace || existsTrace)

            return ParsedEntry(host: host, label: label, duplicate: allSelected)
        }
    }

    private func doImport() {
        let newEntries = preview.filter { !$0.duplicate }
        for entry in newEntries {
            if addToPing  { settings.pingTargets.append(PingTarget(host: entry.host, label: entry.label.isEmpty ? nil : entry.label)) }
            if addToDNS   { settings.dnsTargets.append(DNSTarget(domain: entry.host)) }
            if addToTrace { settings.tracerouteTargets.append(entry.host) }
        }
        importCount = newEntries.count
        didImport   = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { dismiss() }
        }
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

// MARK: - Alerting Tab

struct AlertingTab: View {
    @Binding var settings: MonitorSettings
    @EnvironmentObject var notificationManager: NetWatchNotificationManager
    @State private var testResult: String = ""
    @State private var isTesting   = false
    @State private var notifTestSent = false

    var body: some View {
        Form {
            // ── Desktop Notifications ──────────────────────────────────────────
            Section {
                // Master switch
                Toggle(isOn: $settings.desktopNotificationsEnabled) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Desktop Notifications")
                                .fontWeight(.medium)
                            Text("Enable or disable all NetWatch notification banners.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .tint(.blue)

                // Per-type toggles — greyed when master is off
                Group {
                    NotifTypeRow(
                        label: "Incidents",
                        subtitle: "When NetWatch creates an incident bundle",
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        isOn: $settings.notifyOnIncident
                    )
                    NotifTypeRow(
                        label: "Connectivity Loss",
                        subtitle: "When all ping targets fail simultaneously",
                        icon: "wifi.slash",
                        color: .red,
                        isOn: $settings.notifyOnConnectivityLoss
                    )
                    NotifTypeRow(
                        label: "Signal Degradation",
                        subtitle: "When modem DS SNR or US Tx power crosses a threshold",
                        icon: "waveform.path.ecg",
                        color: .yellow,
                        isOn: $settings.notifyOnSignalDegradation
                    )
                    NotifTypeRow(
                        label: "Auto-Remediation",
                        subtitle: "When NetWatch takes a corrective action (e.g. DNS failover)",
                        icon: "wand.and.stars",
                        color: .green,
                        isOn: $settings.notifyOnRemediation
                    )
                    NotifTypeRow(
                        label: "Update Available",
                        subtitle: "When a new NetWatch version is published on GitHub",
                        icon: "arrow.down.circle",
                        color: .blue,
                        isOn: $settings.notifyOnUpdateAvailable
                    )

                    HStack {
                        Button(notifTestSent ? "Notification sent ✓" : "Send Test Notification") {
                            notificationManager.sendTest()
                            notifTestSent = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                notifTestSent = false
                            }
                        }
                        .disabled(!settings.desktopNotificationsEnabled)
                        Spacer()
                    }
                }
                .opacity(settings.desktopNotificationsEnabled ? 1.0 : 0.4)
                .disabled(!settings.desktopNotificationsEnabled)
            } header: {
                Text("Desktop Notifications")
            } footer: {
                Text("Notification settings take effect after pressing Apply & Restart. Signal Degradation is off by default — cable modem signal fluctuates frequently.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Webhook ────────────────────────────────────────────────────────
            Section {
                LabeledContent("Webhook URL") {
                    TextField("https://hooks.slack.com/… or custom URL",
                              text: $settings.webhookURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                }
                .help("Slack Incoming Webhook or any HTTP endpoint that accepts JSON POST")

                LabeledContent("Alert when health score below") {
                    HStack {
                        Stepper(value: $settings.alertOnHealthScoreBelow, in: 0...100, step: 5) {
                            Text(settings.alertOnHealthScoreBelow == 0
                                 ? "All incidents"
                                 : "< \(settings.alertOnHealthScoreBelow)/100")
                                .monospacedDigit()
                        }
                    }
                }
                .help("0 = alert on every incident regardless of health score")

                // Test button
                HStack {
                    Spacer()
                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.contains("✓") ? .green : .red)
                    }
                    Button {
                        Task { await testWebhook() }
                    } label: {
                        if isTesting {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.7)
                                Text("Sending…")
                            }
                        } else {
                            Text("Send Test Alert")
                        }
                    }
                    .disabled(settings.webhookURL.isEmpty || isTesting)
                }
            } header: {
                Text("Webhook Alerts")
            } footer: {
                Text("Supports Slack Incoming Webhooks and any generic JSON HTTP endpoint. Leave blank to disable.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Speed Test ────────────────────────────────────────────────────
            Section {
                LabeledContent("Alert when download below") {
                    HStack(spacing: 6) {
                        TextField("Mbps", value: $settings.speedTestAlertThresholdMbps,
                                  format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        Text("Mbps")
                            .foregroundStyle(.secondary)
                        if settings.speedTestAlertThresholdMbps == 0 {
                            Text("(disabled)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .help("Fire a webhook alert when a speed test's download result drops below this threshold. Set 0 to disable.")
            } header: {
                Text("Speed Test Alerts")
            } footer: {
                Text("Triggers after each manual or scheduled speed test. Requires a webhook URL above.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Bandwidth Budget ───────────────────────────────────────────────
            Section {
                LabeledContent("Weekly budget") {
                    HStack(spacing: 6) {
                        TextField("GB", value: $settings.weeklyBandwidthBudgetGB,
                                  format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        Text("GB / week")
                            .foregroundStyle(.secondary)
                        if settings.weeklyBandwidthBudgetGB == 0 {
                            Text("(disabled)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .help("Set 0 to disable bandwidth budget monitoring")

                LabeledContent("Alert cooldown") {
                    HStack(spacing: 6) {
                        Stepper(value: $settings.bandwidthAlertCooldownHours,
                                in: 1...168, step: 1) {
                            Text("\(Int(settings.bandwidthAlertCooldownHours)) h")
                                .monospacedDigit()
                        }
                    }
                }
                .help("Minimum hours between repeated bandwidth alerts")
            } header: {
                Text("Bandwidth Budget")
            } footer: {
                Text("Alerts fire at 80% and 100% of the weekly budget. Data sourced from Nighthawk traffic meter (most accurate) or Firewalla device totals.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // ── Auto-Remediation ───────────────────────────────────────────────
            Section {
                Toggle("Enable auto-remediation", isOn: $settings.remediationEnabled)
                    .help("When enabled, NetWatch can take corrective actions (e.g. switch DNS) to restore connectivity automatically.")

                if settings.remediationEnabled {
                    LabeledContent("DNS fail threshold") {
                        Stepper("\(settings.remediationFailThreshold) consecutive",
                                value: $settings.remediationFailThreshold, in: 2...10)
                    }
                    .help("Consecutive ping failures on primary DNS targets before triggering DNS failover.")

                    LabeledContent("Backup DNS servers") {
                        TextField("9.9.9.9 208.67.222.222",
                                  text: Binding(
                                    get: { settings.remediationBackupDNS.joined(separator: " ") },
                                    set: { settings.remediationBackupDNS = $0.split(separator: " ").map(String.init) }
                                  ))
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 180)
                    }
                    .help("Space-separated list of fallback DNS server IPs used during DNS failover.")
                }
            } header: {
                Text("Auto-Remediation")
            } footer: {
                Text("DNS Failover: when 1.1.1.1 and 8.8.8.8 are unreachable, switches system DNS to backup servers via networksetup. Restored automatically on recovery. Actions are logged in the Remediation Log (Incidents tab).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ── Mobile API ─────────────────────────────────────────────────────
            Section {
                Toggle("Enable Mobile API server", isOn: $settings.mobileAPIEnabled)
                    .help("Start a local HTTP JSON API so NetWatch Mobile (iOS) can query live status from the same LAN or via WireGuard VPN.")

                if settings.mobileAPIEnabled {
                    LabeledContent("Port") {
                        HStack(spacing: 6) {
                            TextField("57821", value: Binding(
                                get: { Int(settings.mobileAPIPort) },
                                set: { settings.mobileAPIPort = UInt16(max(1024, min(65535, $0))) }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            Text("(default 57821)").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    // curl test snippet
                    LabeledContent("Test") {
                        Text("curl http://localhost:\(settings.mobileAPIPort)/health")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Mobile API (NetWatch iOS)")
            } footer: {
                Text("Exposes read-only JSON endpoints: /health, /connectors, /status, /incidents. The iOS companion app connects on LAN or via WireGuard VPN. No auth token required — WireGuard is the security boundary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500)
    }

    // MARK: - Test webhook

    private func testWebhook() async {
        guard !settings.webhookURL.isEmpty else { return }
        isTesting  = true
        testResult = ""
        let testDiagnosis = StackDiagnosis(
            timestamp: Date(), healthScore: 72,
            rootCause: .modem, confidence: .medium,
            summary: "This is a test alert from NetWatch",
            layerResults: [], recommendations: ["Verify webhook configuration"]
        )
        await WebhookAlerter.sendIncident(
            reason: "Test Alert",
            diagnosis: testDiagnosis,
            webhookURL: settings.webhookURL
        )
        isTesting  = false
        testResult = "✓ Sent (check your webhook endpoint)"
    }
}

// MARK: - NotifTypeRow helper

private struct NotifTypeRow: View {
    let label:    String
    let subtitle: String
    let icon:     String
    let color:    Color
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - About Tab

private struct AboutTab: View {
    @EnvironmentObject var updateChecker: UpdateChecker

    private let githubURL   = URL(string: "https://github.com/lswingrover/NetWatch")!
    private let releasesURL = URL(string: "https://github.com/lswingrover/NetWatch/releases")!

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "network")
                        .font(.system(size: 40))
                        .foregroundStyle(.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NetWatch")
                            .font(.title2).fontWeight(.semibold)
                        Text("Version \(updateChecker.currentVersion)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section("Updates") {
                if updateChecker.updateAvailable {
                    HStack {
                        Label("Version \(updateChecker.latestVersion) available",
                              systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.accentColor)
                        Spacer()
                        if let url = updateChecker.releaseURL {
                            Button("View Release") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                } else {
                    Label("NetWatch is up to date", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button("Check for Updates Now") { updateChecker.checkNow() }
                    .buttonStyle(.borderless)
            }

            Section("GitHub") {
                Button {
                    NSWorkspace.shared.open(githubURL)
                } label: {
                    Label("View Repository", systemImage: "safari")
                }
                .buttonStyle(.borderless)

                Button {
                    NSWorkspace.shared.open(releasesURL)
                } label: {
                    Label("All Releases", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
    }
}
}
