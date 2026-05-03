import SwiftUI
import UserNotifications

@main
struct NetWatchApp: App {
    @StateObject private var monitor       = NetworkMonitorService()
    @StateObject private var updateChecker = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(monitor.interfaceMonitor)
                .environmentObject(monitor.tracerouteMonitor)
                .environmentObject(monitor.connectorManager)
                .environmentObject(monitor.incidentManager)
                .environmentObject(monitor.speedTestMonitor)
                .environmentObject(monitor.remediationEngine)
                .environmentObject(updateChecker)
                .onAppear {
                    registerConnectors()
                    monitor.start()
                    updateChecker.start()
                    UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound]) { _, _ in }
                }
                .onDisappear {
                    monitor.stop()
                    updateChecker.stop()
                }
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About NetWatch") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "NetWatch",
                        .applicationVersion: "1.3.1",
                        .credits: NSAttributedString(string: "Network monitoring dashboard.\nBuilt by Louis Swingrover.")
                    ])
                }
            }
            CommandMenu("Monitor") {
                Button(monitor.isRunning ? "Pause Monitoring" : "Resume Monitoring") {
                    if monitor.isRunning { monitor.stop() } else { monitor.start() }
                }
                .keyboardShortcut("p", modifiers: .command)

                Divider()

                Button("Run Speed Test") {
                    monitor.speedTestMonitor.runTest()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(monitor.speedTestMonitor.isRunning)

                Button("Run Traceroute Now") {
                    for target in monitor.settings.tracerouteTargets {
                        monitor.tracerouteMonitor.runNow(target: target)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Open Logs Folder") {
                    let base = (monitor.settings.baseDirectory as NSString).expandingTildeInPath
                    let logs = URL(fileURLWithPath: base).appendingPathComponent("logs")
                    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(logs)
                }

                Button("Open Incidents Folder") {
                    let base = (monitor.settings.baseDirectory as NSString).expandingTildeInPath
                    let inc  = URL(fileURLWithPath: base).appendingPathComponent("incidents")
                    try? FileManager.default.createDirectory(at: inc, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(inc)
                }
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(monitor)
                .frame(width: 600, height: 520)
        }

        MenuBarExtra {
            MenuBarStatusView()
                .environmentObject(monitor)
                .environmentObject(monitor.interfaceMonitor)
                .environmentObject(monitor.speedTestMonitor)
        } label: {
            Image(systemName: monitor.overallStatus.systemImage)
                .foregroundStyle(
                    monitor.overallStatus == .healthy  ? Color.green  :
                    monitor.overallStatus == .degraded ? Color.yellow : Color.red
                )
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: - Connector Registration

    /// Register all built-in device connectors with the shared registry.
    ///
    /// To add support for a new device:
    ///   1. Create a class conforming to `DeviceConnector` (use FirewallaConnector as reference).
    ///   2. Define a `ConnectorDescriptor` with your device's metadata below.
    ///   3. Call `ConnectorRegistry.shared.register(descriptor, factory:)` here.
    ///   No other files need to change.
    private func registerConnectors() {
        // ── Firewalla ─────────────────────────────────────────────────────────
        let firewallaDescriptor = ConnectorDescriptor(
            id: "firewalla",
            displayName: "Firewalla",
            iconName: "shield.lefthalf.filled",
            description: "Security events, alarms, device activity, and WAN status from your Firewalla Gold via SSH→Redis.",
            vendor: "Firewalla Inc.",
            docsURL: "https://github.com/lswingrover/NetWatch#firewalla-connector",
            configHelp: ConnectorConfigHelp(
                hostPlaceholder: "Leave blank (reads from ~/.env)",
                hostHelp: "Optional: path to snapshot script (leave blank to use ~/Documents/Claude/mcp-servers/netwatch-firewalla-snapshot.py). Credentials are read from ~/.env — see FIREWALLA_IP, FIREWALLA_SSH_USER, FIREWALLA_SSH_PASS_UUID.",
                apiKeyLabel: "",
                apiKeyHelp: "",
                usernameLabel: "",
                passwordLabel: "",
                showCredentials: false
            )
        )
        ConnectorRegistry.shared.register(firewallaDescriptor) { FirewallaConnector(config: $0) }

        // ── Netgear CM3000 cable modem ────────────────────────────────────────
        let cm3000Descriptor = ConnectorDescriptor(
            id: "cm3000",
            displayName: "Netgear CM3000",
            iconName: "cable.connector.horizontal",
            description: "DOCSIS downstream/upstream signal quality (SNR, power levels), channel counts, startup status, and error events from your Netgear CM3000 cable modem via SSH tunnel.",
            vendor: "Netgear",
            docsURL: "https://github.com/lswingrover/NetWatch#cm3000-connector",
            configHelp: ConnectorConfigHelp(
                hostPlaceholder: "Leave blank (reads from ~/.env)",
                hostHelp: "Optional: path to snapshot script. Credentials read from ~/.env — FIREWALLA_SSH_PASS_UUID (Firewalla SSH) and CM3000_1PASS_ITEM (modem admin password). Modem is reached via SSH tunnel through Firewalla.",
                apiKeyLabel: "",
                apiKeyHelp: "",
                usernameLabel: "",
                passwordLabel: "",
                showCredentials: false
            )
        )
        ConnectorRegistry.shared.register(cm3000Descriptor) { CM3000Connector(config: $0) }

        // ── Netgear Orbi ──────────────────────────────────────────────────────
        let orbiDescriptor = ConnectorDescriptor(
            id: "orbi",
            displayName: "Netgear Orbi",
            iconName: "wifi.router.fill",
            description: "WAN IP, uptime, traffic meter, and WAN status from your Netgear Orbi mesh system (HTTPS, port 443).",
            vendor: "Netgear",
            docsURL: "https://github.com/lswingrover/NetWatch#orbi-connector",
            configHelp: ConnectorConfigHelp(
                hostPlaceholder: "Leave blank (reads from ~/.env)",
                hostHelp: "Credentials read from ~/.env — ORBI_HOST (router IP), ORBI_USER (default: admin), ORBI_PASS (admin password).",
                apiKeyLabel: "",
                apiKeyHelp: "",
                usernameLabel: "",
                passwordLabel: "",
                showCredentials: false
            )
        )
        ConnectorRegistry.shared.register(orbiDescriptor) { OrbiConnector(config: $0) }
    }
}
