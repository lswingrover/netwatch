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
                        .applicationVersion: "1.3.0",
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
            description: "Security events, bandwidth, and device activity from your Firewalla Gold, Purple, or Blue+.",
            vendor: "Firewalla Inc.",
            docsURL: "https://github.com/lswingrover/NetWatch#firewalla-connector",
            configHelp: ConnectorConfigHelp(
                hostPlaceholder: "192.168.1.1",
                hostHelp: "Local IP of your Firewalla",
                apiKeyLabel: "Box API Token",
                apiKeyHelp: "Firewalla app → More → Settings → API Access",
                usernameLabel: "",
                passwordLabel: "",
                showCredentials: false
            )
        )
        ConnectorRegistry.shared.register(firewallaDescriptor) { FirewallaConnector(config: $0) }

        // ── Netgear Nighthawk ─────────────────────────────────────────────────
        let nighthawkDescriptor = ConnectorDescriptor(
            id: "nighthawk",
            displayName: "Netgear Nighthawk",
            iconName: "wifi.router",
            description: "WAN IP, uptime, traffic meter, and connection state from your Netgear Nighthawk router (HTTP, port 5000).",
            vendor: "Netgear",
            docsURL: "https://github.com/lswingrover/NetWatch#nighthawk-connector",
            configHelp: ConnectorConfigHelp(
                hostPlaceholder: "192.168.1.1",
                hostHelp: "Local IP of your Nighthawk (usually 192.168.1.1)",
                apiKeyLabel: "",
                apiKeyHelp: "",
                usernameLabel: "Username",
                passwordLabel: "Admin Password",
                showCredentials: true
            )
        )
        ConnectorRegistry.shared.register(nighthawkDescriptor) { NightawkConnector(config: $0) }

        // ── Netgear Orbi ──────────────────────────────────────────────────────
        let orbiDescriptor = ConnectorDescriptor(
            id: "orbi",
            displayName: "Netgear Orbi",
            iconName: "wifi.router.fill",
            description: "WAN IP, uptime, traffic meter, and WAN status from your Netgear Orbi mesh system (HTTPS, port 443).",
            vendor: "Netgear",
            docsURL: "https://github.com/lswingrover/NetWatch#orbi-connector",
            configHelp: ConnectorConfigHelp(
                hostPlaceholder: "192.168.40.161",
                hostHelp: "Local IP of your Orbi router (not satellite)",
                apiKeyLabel: "",
                apiKeyHelp: "",
                usernameLabel: "Username",
                passwordLabel: "Admin Password",
                showCredentials: true
            )
        )
        ConnectorRegistry.shared.register(orbiDescriptor) { OrbiConnector(config: $0) }
    }
}
