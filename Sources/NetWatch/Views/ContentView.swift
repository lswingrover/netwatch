import SwiftUI

enum NavItem: String, CaseIterable, Identifiable {
    case overview   = "Overview"
    case timeline   = "Timeline"
    case ping       = "Ping Targets"
    case dns        = "DNS"
    case traceroute = "Traceroute"
    case devices    = "Devices"
    case topology   = "Topology"
    case openPorts  = "Open Ports"
    case speedTest  = "Speed Test"
    case incidents  = "Incidents"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview:   "gauge.with.dots.needle.bottom.50percent"
        case .timeline:   "timeline.selection"
        case .ping:       "antenna.radiowaves.left.and.right"
        case .dns:        "server.rack"
        case .traceroute: "point.3.connected.trianglepath.dotted"
        case .devices:    "cable.connector.horizontal"
        case .topology:   "point.3.filled.connected.trianglepath.dotted"
        case .openPorts:  "lock.open.display"
        case .speedTest:  "speedometer"
        case .incidents:  "exclamationmark.triangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var monitor:          NetworkMonitorService
    @EnvironmentObject var ifMonitor:        InterfaceMonitor
    @EnvironmentObject var connectorManager: ConnectorManager
    @EnvironmentObject var updateChecker:    UpdateChecker
    @State private var selection:           NavItem = .overview
    @State private var showPalette:         Bool    = false
    @State private var updateBannerDismissed = false
    /// Set by topology node taps to deep-link into a specific connector in ConnectorsView.
    @State private var pendingConnectorID:  String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Update banner ─────────────────────────────────────────────────
            if updateChecker.updateAvailable && !updateBannerDismissed {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("NetWatch \(updateChecker.latestVersion) is available")
                        .font(.subheadline).fontWeight(.medium)
                    Spacer()
                    if let url = updateChecker.releaseURL {
                        Button("View Release") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Button { withAnimation { updateBannerDismissed = true } } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

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
                case .timeline:   TimelineView()
                case .ping:       PingView()
                case .dns:        DNSView()
                case .traceroute: TracerouteView()
                case .devices:    ConnectorsView(requestedConnectorID: $pendingConnectorID)
                case .topology:
                    TopologyView { nodeId in
                        selection = .devices
                        pendingConnectorID = nodeId
                    }
                case .openPorts:  OpenPortsView()
                case .speedTest:  SpeedTestView()
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
                ToolbarItem {
                    Button {
                        showPalette = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Command palette (⌘K)")
                    .keyboardShortcut("k", modifiers: .command)
                }
            }
            .sheet(isPresented: $showPalette) {
                CommandPaletteView(selection: $selection, isPresented: $showPalette)
                    .environmentObject(monitor)
            }
        }
        } // VStack
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
