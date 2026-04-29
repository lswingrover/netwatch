import SwiftUI

enum NavItem: String, CaseIterable, Identifiable {
    case overview   = "Overview"
    case ping       = "Ping Targets"
    case dns        = "DNS"
    case traceroute = "Traceroute"
    case incidents  = "Incidents"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview:   "gauge.with.dots.needle.bottom.50percent"
        case .ping:       "antenna.radiowaves.left.and.right"
        case .dns:        "server.rack"
        case .traceroute: "point.3.connected.trianglepath.dotted"
        case .incidents:  "exclamationmark.triangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var monitor: NetworkMonitorService
    @EnvironmentObject var ifMonitor: InterfaceMonitor
    @State private var selection: NavItem = .overview

    var body: some View {
        NavigationSplitView {
            List(NavItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.systemImage)
                    .badge(item == .incidents ? monitor.incidentManager.incidents.count : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .toolbar {
                ToolbarItem {
                    StatusDot(status: monitor.overallStatus)
                        .help(monitor.overallStatus.label)
                }
            }
        } detail: {
            Group {
                switch selection {
                case .overview:   OverviewView()
                case .ping:       PingView()
                case .dns:        DNSView()
                case .traceroute: TracerouteView()
                case .incidents:  IncidentsView()
                }
            }
            .navigationTitle(selection.rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if monitor.isRunning { monitor.stop() } else { monitor.start() }
                    } label: {
                        Label(monitor.isRunning ? "Pause" : "Resume",
                              systemImage: monitor.isRunning ? "pause.circle" : "play.circle")
                    }
                    .help(monitor.isRunning ? "Pause monitoring" : "Resume monitoring")
                }
            }
        }
    }
}

struct StatusDot: View {
    let status: NetworkStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 10, height: 10)
            .scaleEffect(pulse && status != .healthy ? 1.2 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                       value: pulse)
            .onAppear { pulse = true }
    }

    var dotColor: Color {
        switch status {
        case .healthy:  .green
        case .degraded: .yellow
        case .critical: .red
        }
    }
}
