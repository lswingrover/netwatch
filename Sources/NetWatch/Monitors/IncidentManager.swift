import Foundation
import UserNotifications

@MainActor
class IncidentManager: ObservableObject {
    @Published var incidents: [Incident] = []

    private let baseDir: URL
    private var lastIncidentTime: Date = .distantPast
    private let cooldown: TimeInterval

    init(baseDirectory: String = "~/network_tests", cooldown: TimeInterval = 60) {
        let expanded = (baseDirectory as NSString).expandingTildeInPath
        self.baseDir = URL(fileURLWithPath: expanded)
        self.cooldown = cooldown
        loadExistingIncidents()
    }

    /// Call from NetworkMonitorService when failure thresholds are breached.
    /// `connectorSnapshots` is optional — pass whatever the ConnectorManager has at the moment.
    /// Webhook URL for alerting — set from MonitorSettings before incidents fire.
    var webhookURL: String = ""

    /// Health-score alert threshold. When a diagnosis score drops below this, fire webhook.
    var healthScoreAlertThreshold: Int = 0

    func considerIncident(reason: String, subject: String,
                          pingStates: [PingState], dnsStates: [DNSState],
                          traceroute: TracerouteResult?,
                          connectorSnapshots: [ConnectorSnapshot] = []) {
        let now = Date()
        guard now.timeIntervalSince(lastIncidentTime) >= cooldown else { return }
        lastIncidentTime = now
        Task { _ = await bundleIncident(reason: reason, subject: subject,
                                        pingStates: pingStates, dnsStates: dnsStates,
                                        traceroute: traceroute,
                                        connectorSnapshots: connectorSnapshots) }
    }

    /// Manually trigger a full incident report bundle, bypassing the cooldown.
    /// Returns the bundle directory URL on success, or nil if bundle creation failed.
    /// Intended for the "Generate Report" button in StackHealthView.
    @discardableResult
    func triggerManualReport(reason: String,
                             note: String,
                             pingStates: [PingState],
                             dnsStates: [DNSState],
                             traceroute: TracerouteResult?,
                             connectorSnapshots: [ConnectorSnapshot] = []) async -> URL? {
        let subject = note.isEmpty ? "Manual report — \(Self.timestamp())" : note
        return await bundleIncident(
            reason: "Manual Report: \(reason)",
            subject: subject,
            pingStates: pingStates,
            dnsStates: dnsStates,
            traceroute: traceroute,
            connectorSnapshots: connectorSnapshots
        )
    }

    // MARK: - Private

    @discardableResult
    private func bundleIncident(reason: String, subject: String,
                                pingStates: [PingState], dnsStates: [DNSState],
                                traceroute: TracerouteResult?,
                                connectorSnapshots: [ConnectorSnapshot] = []) async -> URL? {
        let ts = Self.timestamp()
        let dir = baseDir.appendingPathComponent("incidents/incident_\(ts)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { return nil }

        // ── Run stack diagnosis ───────────────────────────────────────────────
        let diagnosis = StackDiagnosisEngine.diagnose(
            pingStates: pingStates,
            dnsStates:  dnsStates,
            traceroute: traceroute,
            snapshots:  connectorSnapshots
        )
        // Write diagnosis report
        try? diagnosis.report().write(
            to: dir.appendingPathComponent("stack_diagnosis.txt"),
            atomically: true, encoding: .utf8)

        // incident.txt
        var summary = """
        Incident Report
        Generated: \(Date())
        Reason:    \(reason)
        Subject:   \(subject)
        Health Score: \(diagnosis.healthScore)/100
        Root Cause: \(diagnosis.rootCause.rawValue) (\(diagnosis.confidence.rawValue) confidence)
        Diagnosis: \(diagnosis.summary)

        === Ping Status ===
        """
        for ps in pingStates {
            let avg = ps.avgRTT.rttString
            let last = ps.lastRTT.rttString
            let ok = ps.isOnline ? "OK" : "FAIL"
            summary += "\n\(ps.target.host.padding(toLength: 20, withPad: " ", startingAt: 0)) avg=\(avg)  last=\(last)  \(ok)"
        }
        summary += "\n\n=== DNS Status ===\n"
        for ds in dnsStates {
            let rate = String(format: "%.1f%%", ds.successRate * 100)
            let last = ds.lastQueryTime.rttString
            summary += "\n\(ds.target.domain.padding(toLength: 24, withPad: " ", startingAt: 0)) success=\(rate)  last=\(last)  \(ds.lastStatus)"
        }

        if let tr = traceroute {
            summary += "\n\n=== Traceroute → \(tr.target) (\(tr.hopCount) hops) ===\n"
            for hop in tr.hops {
                let ip = hop.ip ?? "*"
                let rtt = hop.avgRTT.map { String(format: "%.1fms", $0) } ?? "* * *"
                summary += "\n  \(String(format: "%2d", hop.id))  \(ip.padding(toLength: 18, withPad: " ", startingAt: 0))  \(rtt)"
            }
        }

        // Tier-2 ISP ticket draft
        let ticket = """
        === ISP Escalation Draft ===
        Date/Time: \(Date())
        Issue: \(reason) — \(subject)

        Network Health Score: \(diagnosis.healthScore)/100
        Root Cause Analysis: \(diagnosis.summary)

        Key metrics at time of incident:
        \(pingStates.map { "  \($0.target.host): avg \($0.avgRTT.rttString), loss \(String(format: "%.0f%%", (1 - $0.successRate) * 100))" }.joined(separator: "\n"))

        DNS success rates:
        \(dnsStates.map { "  \($0.target.domain): \(String(format: "%.1f%%", $0.successRate * 100))" }.joined(separator: "\n"))

        \(traceroute.map { "Traceroute to \($0.target): \($0.hopCount) hops" } ?? "")

        Recommended next steps:
        \(diagnosis.recommendations.map { "  • \($0)" }.joined(separator: "\n"))

        Please investigate. Full stack diagnosis report is attached as stack_diagnosis.txt.
        """

        try? summary.write(to: dir.appendingPathComponent("incident.txt"), atomically: true, encoding: .utf8)
        try? ticket.write(to: dir.appendingPathComponent("tier2_ticket.txt"), atomically: true, encoding: .utf8)

        // Device connector snapshots — one file per connector
        for snap in connectorSnapshots {
            var lines = "=== \(snap.connectorName) — \(snap.timestamp) ===\n"
            lines += "Summary: \(snap.summary)\n\n"
            if !snap.metrics.isEmpty {
                lines += "Metrics:\n"
                for m in snap.metrics {
                    lines += "  \(m.label.padding(toLength: 20, withPad: " ", startingAt: 0)) \(m.value) \(m.unit)  [\(m.severity.rawValue)]\n"
                }
            }
            if !snap.events.isEmpty {
                lines += "\nEvents:\n"
                for e in snap.events {
                    lines += "  [\(e.timestamp)] \(e.type.uppercased())  \(e.description)  [\(e.severity.rawValue)]\n"
                }
            }
            let safeId = snap.connectorId.replacingOccurrences(of: "/", with: "_")
            let file = dir.appendingPathComponent("connector_\(safeId).txt")
            try? lines.write(to: file, atomically: true, encoding: .utf8)
        }

        // Snapshot: recent ping histories
        for ps in pingStates {
            let lines = ps.results.suffix(50).map { r in
                "[\(r.timestamp)] \(r.success ? "OK" : "FAIL") \(r.host) rtt=\(r.rtt.rttString)"
            }.joined(separator: "\n")
            let file = dir.appendingPathComponent("ping_\(ps.target.host.replacingOccurrences(of: ".", with: "_")).txt")
            try? lines.write(to: file, atomically: true, encoding: .utf8)
        }

        let incident = Incident(
            id: UUID(),
            timestamp: Date(),
            reason: reason,
            subject: subject,
            bundlePath: dir
        )
        incidents.insert(incident, at: 0)
        if incidents.count > 200 { incidents.removeLast() }

        // System notification
        let content = UNMutableNotificationContent()
        content.title = "NetWatch — \(reason)"
        content.body  = subject
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "netwatch-\(incident.id.uuidString)",
            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)

        // Webhook alert (fire-and-forget; errors logged to stderr)
        if !webhookURL.isEmpty {
            let shouldAlert = healthScoreAlertThreshold == 0
                           || diagnosis.healthScore < healthScoreAlertThreshold
            if shouldAlert {
                await WebhookAlerter.sendIncident(
                    reason:     reason,
                    diagnosis:  diagnosis,
                    webhookURL: webhookURL
                )
            }
        }

        return dir
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: Date())
    }

    private func loadExistingIncidents() {
        let incDir = baseDir.appendingPathComponent("incidents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: incDir, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var loaded: [Incident] = []
        for entry in entries where entry.lastPathComponent.hasPrefix("incident_") {
            let attrs = try? entry.resourceValues(forKeys: [.creationDateKey])
            let date  = attrs?.creationDate ?? Date()
            let txt   = try? String(contentsOf: entry.appendingPathComponent("incident.txt"))
            var reason = "Unknown"
            var subject = entry.lastPathComponent
            if let txt = txt {
                for line in txt.components(separatedBy: "\n") {
                    if line.hasPrefix("Reason:") { reason = line.replacingOccurrences(of: "Reason:", with: "").trimmingCharacters(in: .whitespaces) }
                    if line.hasPrefix("Subject:") { subject = line.replacingOccurrences(of: "Subject:", with: "").trimmingCharacters(in: .whitespaces) }
                }
            }
            loaded.append(Incident(id: UUID(), timestamp: date, reason: reason, subject: subject, bundlePath: entry))
        }
        incidents = loaded.sorted { $0.timestamp > $1.timestamp }
    }
}
