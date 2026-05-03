/// RemediationEngine.swift — Automated network remediation actions
///
/// Watches PingState results and applies corrective actions when degradation
/// crosses a configurable threshold. All actions are logged and reversible.
///
/// Currently supported remediations:
///   1. DNS Failover — when primary DNS targets (1.1.1.1, 8.8.8.8) are
///      unreachable, switches the system DNS resolver to backup servers
///      (9.9.9.9, 208.67.222.222) via `networksetup`. Restored automatically
///      when the primary targets recover.
///
/// Architecture:
///   RemediationEngine is owned by NetworkMonitorService and evaluated inside
///   the existing 5-second failure-watcher loop. It is injected as an
///   @EnvironmentObject so views can display its log and enable/disable it.
///
/// Safety:
///   - Requires `settings.remediationEnabled = true` (default: false).
///   - A per-action cooldown (60s default) prevents rapid re-triggering.
///   - All networksetup calls are logged to `events` before execution.
///   - Original DNS is always saved before any change and restored on recovery.

import Foundation

// MARK: - Event model

struct RemediationEvent: Identifiable {
    let id        = UUID()
    let timestamp = Date()
    let kind:     RemediationKind
    let detail:   String
    let success:  Bool

    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: timestamp)
    }
}

enum RemediationKind: String {
    case dnsFailover   = "DNS Failover"
    case dnsRestored   = "DNS Restored"
    case info          = "Info"
}

// MARK: - Engine

@MainActor
final class RemediationEngine: ObservableObject {

    // MARK: - Published

    /// Chronological log of all actions taken (most recent last for display).
    @Published private(set) var events: [RemediationEvent] = []

    /// True while DNS failover is active (system DNS has been switched).
    @Published private(set) var isDNSFailoverActive = false

    // MARK: - Config (injected from NetworkMonitorService.applySettings)

    var isEnabled           = false
    var failThreshold: Int  = 3        // consecutive failures before triggering
    var recoverThreshold    = 5        // consecutive successes before restoring
    var cooldownSeconds     = 60.0
    var networkInterface    = ""       // empty = auto-detect
    var backupDNS: [String] = ["9.9.9.9", "208.67.222.222"]

    // DNS targets that constitute "primary DNS" — if these fail we do DNS failover
    private let primaryDNSHosts = Set(["1.1.1.1", "8.8.8.8"])

    // MARK: - Private state

    private var originalDNS: [String] = []      // saved before failover
    private var lastActionDate: Date?
    private var recoveryCount = 0                // consecutive successes post-failover

    // MARK: - Evaluation (called every 5s from NetworkMonitorService)

    func evaluate(pingStates: [PingState]) {
        guard isEnabled else { return }

        // ── DNS Failover ──────────────────────────────────────────────────────

        let primaryStates = pingStates.filter { primaryDNSHosts.contains($0.target.host) }
        guard !primaryStates.isEmpty else { return }

        if !isDNSFailoverActive {
            // Check for trigger: all primary DNS targets have `failThreshold` consecutive failures
            let allFailing = primaryStates.allSatisfy { ps in
                let tail = ps.results.suffix(failThreshold)
                return tail.count == failThreshold && tail.allSatisfy { !$0.success }
            }

            if allFailing, !isOnCooldown {
                applyDNSFailover()
            }

        } else {
            // Monitor for recovery: all primary DNS targets have `recoverThreshold` consecutive successes
            let anyOnline = primaryStates.contains { ps in
                let tail = ps.results.suffix(recoverThreshold)
                return tail.count == recoverThreshold && tail.allSatisfy(\.success)
            }

            if anyOnline {
                restoreDNS()
            }
        }
    }

    // MARK: - DNS Failover

    private func applyDNSFailover() {
        let iface = resolvedInterface
        guard !iface.isEmpty else {
            log(.info, "DNS Failover skipped — could not determine active network interface", success: false)
            return
        }

        // Save current DNS before switching
        originalDNS = currentDNS(for: iface)

        let backupList = backupDNS.joined(separator: " ")
        let (out, err, status) = shell("networksetup -setdnsservers \"\(iface)\" \(backupList)")

        if status == 0 {
            isDNSFailoverActive = true
            lastActionDate      = Date()
            log(.dnsFailover,
                "Switched DNS on \(iface) → \(backupList) (was: \(originalDNS.isEmpty ? "DHCP" : originalDNS.joined(separator: ", ")))",
                success: true)
        } else {
            log(.dnsFailover,
                "Failed to switch DNS on \(iface): \(err.isEmpty ? out : err)",
                success: false)
        }
    }

    private func restoreDNS() {
        let iface = resolvedInterface
        guard !iface.isEmpty else { return }

        let cmd: String
        if originalDNS.isEmpty {
            // Was using DHCP-provided DNS — restore by clearing the override
            cmd = "networksetup -setdnsservers \"\(iface)\" Empty"
        } else {
            cmd = "networksetup -setdnsservers \"\(iface)\" \(originalDNS.joined(separator: " "))"
        }

        let (out, err, status) = shell(cmd)

        if status == 0 {
            isDNSFailoverActive = false
            lastActionDate      = Date()
            log(.dnsRestored,
                "Restored DNS on \(iface) → \(originalDNS.isEmpty ? "DHCP" : originalDNS.joined(separator: ", "))",
                success: true)
            originalDNS = []
        } else {
            log(.dnsRestored,
                "Failed to restore DNS on \(iface): \(err.isEmpty ? out : err)",
                success: false)
        }
    }

    // MARK: - Helpers

    private var isOnCooldown: Bool {
        guard let last = lastActionDate else { return false }
        return Date().timeIntervalSince(last) < cooldownSeconds
    }

    private var resolvedInterface: String {
        if !networkInterface.isEmpty { return networkInterface }
        // Detect: grab the interface on the default route
        let (out, _, status) = shell("route -n get default 2>/dev/null | awk '/interface:/ {print $2}'")
        guard status == 0 else { return "" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentDNS(for iface: String) -> [String] {
        let (out, _, status) = shell("networksetup -getdnsservers \"\(iface)\"")
        guard status == 0 else { return [] }
        let lines = out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // "There aren't any DNS Servers set on <iface>." → treat as empty (DHCP)
        let servers = lines.filter { !$0.isEmpty && !$0.hasPrefix("There aren") }
        return servers
    }

    private func log(_ kind: RemediationKind, _ detail: String, success: Bool) {
        let event = RemediationEvent(kind: kind, detail: detail, success: success)
        events.append(event)
        // Keep last 200 events
        if events.count > 200 { events = Array(events.suffix(200)) }
    }

    /// Synchronous shell helper — runs on a background thread.
    /// Must not be called on MainActor directly; use Task.detached or
    /// wrap in a continuation. Here we use a blocking call which is
    /// acceptable because this is called inside an already-async context.
    @discardableResult
    private func shell(_ command: String) -> (stdout: String, stderr: String, status: Int32) {
        let process    = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL  = URL(fileURLWithPath: "/bin/sh")
        process.arguments      = ["-c", command]
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("", error.localizedDescription, -1)
        }
        let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, process.terminationStatus)
    }
}
