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
    let interfaceMonitor      = InterfaceMonitor(interval: 1.0)
    let tracerouteMonitor     = TracerouteMonitor(interval: 60.0)
    let connectorManager      = ConnectorManager()
    let incidentManager:        IncidentManager
    let bandwidthBudgetMonitor = BandwidthBudgetMonitor()
    let speedTestMonitor:       SpeedTestMonitor
    let remediationEngine       = RemediationEngine()
    let apiServer               = NetWatchAPIServer()
    let notificationManager     = NetWatchNotificationManager()

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
        self.speedTestMonitor = SpeedTestMonitor(baseDirectory: s.baseDirectory)
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
        apiServer.stop()
        failureWatcherTask?.cancel()
        failureWatcherTask = nil
    }

    func restart() {
        settings.save()   // persist before tearing down
        stop()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            start()
        }
    }

    // MARK: - Settings

    func applySettings() {
        // NOTE: save() is intentionally NOT called here.
        // Settings are saved explicitly in restart() (user-initiated) to avoid
        // overwriting persisted settings with an uninitialised default on cold launch.

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

        // Alerting
        incidentManager.webhookURL = settings.webhookURL
        incidentManager.healthScoreAlertThreshold = settings.alertOnHealthScoreBelow
        bandwidthBudgetMonitor.resetAlertState()

        // Speed test
        speedTestMonitor.alertThresholdMbps = settings.speedTestAlertThresholdMbps
        speedTestMonitor.webhookURL         = settings.webhookURL
        speedTestMonitor.setBaseDirectory(settings.baseDirectory)

        // Remediation
        remediationEngine.isEnabled        = settings.remediationEnabled
        remediationEngine.failThreshold    = settings.remediationFailThreshold
        remediationEngine.backupDNS        = settings.remediationBackupDNS
        remediationEngine.networkInterface = settings.networkInterface
        remediationEngine.cooldownSeconds  = settings.incidentCooldownSeconds

        // Desktop notifications — configure manager, then inject into sub-monitors
        notificationManager.isEnabled                = settings.desktopNotificationsEnabled
        notificationManager.notifyOnIncident         = settings.notifyOnIncident
        notificationManager.notifyOnConnectivityLoss = settings.notifyOnConnectivityLoss
        notificationManager.notifyOnSignalDegradation = settings.notifyOnSignalDegradation
        notificationManager.notifyOnRemediation      = settings.notifyOnRemediation
        notificationManager.notifyOnUpdateAvailable  = settings.notifyOnUpdateAvailable
        incidentManager.notificationManager          = notificationManager
        remediationEngine.notificationManager        = notificationManager

        // Wire bandwidth budget check into the poll cycle
        let budgetMonitor = bandwidthBudgetMonitor
        let currentSettings = settings
        connectorManager.onPollComplete = { snapshots in
            await budgetMonitor.check(snapshots: snapshots, settings: currentSettings)
        }

        // Mobile API server
        apiServer.stop()
        if settings.mobileAPIEnabled {
            apiServer.port = settings.mobileAPIPort
            wireAPIProviders()
            apiServer.start()
        }

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
        // Run remediation evaluation first
        remediationEngine.evaluate(pingStates: pingStates)

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

    // MARK: - Mobile API wiring

    private func wireAPIProviders() {
        // Snapshot provider: return all live connector snapshots
        apiServer.snapshotProvider = { [weak self] in
            self?.connectorManager.allSnapshots ?? []
        }

        // Status provider: current Mac interface state
        apiServer.statusProvider = { [weak self] in
            guard let self else {
                return APIStatusPayload(macPublicIP: "", macLocalIP: "", wifiSSID: "",
                                       gatewayRTT: nil, isMonitoring: false, appVersion: "–")
            }
            return APIStatusPayload(
                macPublicIP:  self.interfaceMonitor.publicIP,
                macLocalIP:   self.interfaceMonitor.ipAddress,
                wifiSSID:     self.interfaceMonitor.wifiSSID,
                gatewayRTT:   self.interfaceMonitor.gatewayRTT,
                isMonitoring: self.isRunning,
                appVersion:   "1.3.1"
            )
        }

        // Health provider: full stack diagnosis via StackDiagnosisEngine
        apiServer.healthProvider = { [weak self] in
            guard let self else {
                return APIHealthPayload(score: 0, status: "unknown", timestamp: "", layers: [:])
            }
            let traceroute = self.tracerouteMonitor.results.values.first
            let diagnosis  = StackDiagnosisEngine.diagnose(
                pingStates:  self.pingStates,
                dnsStates:   self.dnsStates,
                traceroute:  traceroute,
                snapshots:   self.connectorManager.allSnapshots
            )
            let iso = ISO8601DateFormatter().string(from: Date())
            let statusStr: String = {
                switch diagnosis.healthScore {
                case 85...: return "healthy"
                case 60..<85: return "degraded"
                default: return "critical"
                }
            }()
            let layerMap = Dictionary(
                uniqueKeysWithValues: diagnosis.layerResults.map { lr in
                    (lr.layer.rawValue, lr.status.rawValue)
                }
            )
            return APIHealthPayload(
                score:     diagnosis.healthScore,
                status:    statusStr,
                timestamp: iso,
                layers:    layerMap
            )
        }

        // Incident provider: recent incidents summary
        apiServer.incidentProvider = { [weak self] in
            guard let self else { return [] }
            return self.incidentManager.incidents.prefix(10).map { incident in
                let iso = ISO8601DateFormatter().string(from: incident.timestamp)
                return APIIncidentSummary(
                    id:          incident.id.uuidString,
                    timestamp:   iso,
                    healthScore: 0,               // Incident struct doesn't store health score at trigger
                    rootCause:   incident.reason,
                    severity:    "warning"         // Incident struct doesn't have severity
                )
            }
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
