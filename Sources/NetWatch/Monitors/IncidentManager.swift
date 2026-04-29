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
    func considerIncident(reason: String, subject: String,
                          pingStates: [PingState], dnsStates: [DNSState],
                          traceroute: TracerouteResult?) {
        let now = Date()
        guard now.timeIntervalSince(lastIncidentTime) >= cooldown else { return }
        lastIncidentTime = now
        Task { await bundleIncident(reason: reason, subject: subject,
                                    pingStates: pingStates, dnsStates: dnsStates,
                                    traceroute: traceroute) }
    }

    // MARK: - Private

    private func bundleIncident(reason: String, subject: String,
                                pingStates: [PingState], dnsStates: [DNSState],
                                traceroute: TracerouteResult?) async {
        let ts = Self.timestamp()
        let dir = baseDir.appendingPathComponent("incidents/incident_\(ts)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { return }

        // incident.txt
        var summary = """
        Incident Report
        Generated: \(Date())
        Reason:    \(reason)
        Subject:   \(subject)

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

        Key metrics at time of incident:
        \(pingStates.map { "  \($0.target.host): avg \($0.avgRTT.rttString), loss \(String(format: "%.0f%%", (1 - $0.successRate) * 100))" }.joined(separator: "\n"))

        DNS success rates:
        \(dnsStates.map { "  \($0.target.domain): \(String(format: "%.1f%%", $0.successRate * 100))" }.joined(separator: "\n"))

        \(traceroute.map { "Traceroute to \($0.target): \($0.hopCount) hops" } ?? "")

        Please investigate. Logs and packet captures are attached.
        """

        try? summary.write(to: dir.appendingPathComponent("incident.txt"), atomically: true, encoding: .utf8)
        try? ticket.write(to: dir.appendingPathComponent("tier2_ticket.txt"), atomically: true, encoding: .utf8)

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
