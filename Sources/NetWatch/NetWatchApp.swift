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
                .environmentObject(monitor.incidentManager)
                .environmentObject(updateChecker)
                .onAppear {
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
                        .applicationVersion: "1.2.0",
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
                .frame(width: 560, height: 480)
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
}
