import Foundation
import Combine

/// Central orchestrator. Owns all monitor instances and publishes aggregated state to views.
@MainActor
class NetworkMonitorService: ObservableObject {

    // MARK: - Published state

    @Published var pingStates: [PingState] = []
    @Published var dnsStates: [DNSState] = []
    @Published var settings: MonitorSettings
    @Published var isRunning: Bool = false

    // Sub-monitors (also ObservableObjects, observed by views)
    let interfaceMonitor  = InterfaceMonitor(interval: 1.0)
    let tracerouteMonitor = TracerouteMonitor(interval: 60.0)
    let connectorManager  = ConnectorManager()
    let incidentManager:  IncidentManager

    // MARK: - Private

    private var pingMonitors: [PingMonitor] = []
    private var dnsMonitors: [DNSMonitor] = []
    private var failureWatcherTask: Task<Void, Never>? = nil

    // MARK: - Init

    init() {
        let s = MonitorSettings.load()
        self.settings = s
        self.incidentManager = IncidentManager(baseDirectory: s.baseDirectory,
                                               cooldown: s.incidentCooldownSeconds)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        applySettings()
    }

    func stop() {
        isRunning = false
        pingMonitors.forEach { m in Task { await m.stop() } }
        pingMonitors = []
        dnsMonitors.forEach  { m in Task { await m.stop() } }
        dnsMonitors = []
        interfaceMonitor.stop()
        tracerouteMonitor.stop()
        connectorManager.stop()
        failureWatcherTask?.cancel()
        failureWatcherTask = nil
    }

    func restart() {
        stop()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            start()
        }
    }

    // MARK: - Settings

    func applySettings() {
        settings.save()

        // Build ping states
        pingStates = settings.pingTargets.map { PingState(target: $0) }
        pingMonitors = pingStates.map { PingMonitor(state: $0, interval: settings.pingIntervalSeconds) }
        pingMonitors.forEach { m in Task { await m.start() } }

        // Build DNS states
        dnsStates = settings.dnsTargets.map { DNSState(target: $0) }
        dnsMonitors = dnsStates.map { DNSMonitor(state: $0, interval: settings.dnsIntervalSeconds) }
        dnsMonitors.forEach { m in Task { await m.start() } }

        // Interface
        interfaceMonitor.start(interface: settings.networkInterface)

        // Traceroute
        tracerouteMonitor.start(targets: settings.tracerouteTargets)

        // Device connectors
        connectorManager.load(configs: settings.connectorConfigs)

        // Failure watcher
        failureWatcherTask?.cancel()
        failureWatcherTask = Task {
            while !Task.isCancelled {
                await checkForIncidents()
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // check every 5s
            }
        }
    }

    // MARK: - Incident detection

    private func checkForIncidents() {
        // Grab latest connector snapshots for enrichment
        let connSnaps = connectorManager.allSnapshots

        // Count ping failures across recent window
        var failedTargets: [String] = []
        for ps in pingStates {
            let recent = ps.results.suffix(settings.pingFailThreshold)
            if recent.count == settings.pingFailThreshold && recent.allSatisfy({ !$0.success }) {
                failedTargets.append(ps.target.host)
            }
        }

        if failedTargets.count >= 2 {
            // Multi-target failure → likely upstream issue
            let latestTraceroute = tracerouteMonitor.results.values.first
            incidentManager.considerIncident(
                reason: "PING_MULTI_FAILURE (\(failedTargets.count) targets)",
                subject: failedTargets.joined(separator: ", "),
                pingStates: pingStates,
                dnsStates: dnsStates,
                traceroute: latestTraceroute,
                connectorSnapshots: connSnaps
            )
            return
        }

        if let failed = failedTargets.first {
            let latestTraceroute = tracerouteMonitor.results.values.first
            incidentManager.considerIncident(
                reason: "PING_FAILURE",
                subject: failed,
                pingStates: pingStates,
                dnsStates: dnsStates,
                traceroute: latestTraceroute,
                connectorSnapshots: connSnaps
            )
        }

        // DNS failures
        var dnsFailDomains: [String] = []
        for ds in dnsStates {
            let recent = ds.results.suffix(settings.dnsFailThreshold)
            if recent.count == settings.dnsFailThreshold && recent.allSatisfy({ !$0.success }) {
                dnsFailDomains.append(ds.target.domain)
            }
        }
        if !dnsFailDomains.isEmpty {
            incidentManager.considerIncident(
                reason: "DNS_FAILURE",
                subject: dnsFailDomains.joined(separator: ", "),
                pingStates: pingStates,
                dnsStates: dnsStates,
                traceroute: nil,
                connectorSnapshots: connSnaps
            )
        }
    }

    // MARK: - Computed helpers

    var overallStatus: NetworkStatus {
        let anyPingDown = pingStates.contains { !$0.isOnline }
        let allPingDown = !pingStates.isEmpty && pingStates.allSatisfy { !$0.isOnline }
        let anyDNSBad   = dnsStates.contains { $0.successRate < 0.8 }
        if allPingDown { return .critical }
        if anyPingDown || anyDNSBad { return .degraded }
        return .healthy
    }
}

enum NetworkStatus {
    case healthy, degraded, critical
    var color: String { switch self { case .healthy: "green"; case .degraded: "yellow"; case .critical: "red" } }
    var label: String { switch self { case .healthy: "Healthy"; case .degraded: "Degraded"; case .critical: "Critical" } }
    var systemImage: String { switch self { case .healthy: "eye"; case .degraded: "eye.trianglebadge.exclamationmark"; case .critical: "eye.slash" } }
}
