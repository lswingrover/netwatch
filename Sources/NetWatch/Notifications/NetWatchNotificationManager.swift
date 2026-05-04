/// NetWatchNotificationManager.swift — NetWatch desktop notification system
///
/// Gated desktop banner delivery for all NetWatch event types.
/// Owned by NetworkMonitorService; injected into IncidentManager and RemediationEngine.
///
/// Gates (checked in order):
///   1. desktopNotificationsEnabled — master switch, blocks everything when false.
///   2. Per-type toggle (notifyOnIncident, notifyOnConnectivityLoss, etc.)
///   3. Per-type cooldown — prevents repeat banners for sustained events.
///
/// Per-type cooldowns:
///   .incident         300s  (5 min)
///   .connectivityLoss  60s  (1 min)
///   .remediation       30s  (30s — actions are always relevant)
///   .updateAvailable 86400s (1 day)
///
/// Wiring (NetworkMonitorService.applySettings):
///   Configure flags from MonitorSettings, then assign to incidentManager and remediationEngine.
///
/// Sprint 1: Foundation.
/// Sprint 2: Add interruptionLevel, quiet hours gate.
/// Sprint 3: Add UNNotificationCategory actions (Run Diagnosis, Open Claude, Undo, etc.)
/// Sprint 4: Cross-app coordination via DistributedNotificationCenter.

import Foundation
import UserNotifications

// MARK: - Type

enum NetWatchNotificationType {
    case incident
    case connectivityLoss
    case remediation
    case updateAvailable
}

// MARK: - Manager

@MainActor
final class NetWatchNotificationManager: ObservableObject {

    // MARK: - Configuration (set by NetworkMonitorService.applySettings)

    /// Master switch — when false, all banners are suppressed.
    var isEnabled: Bool = true

    /// Per-type toggles
    var notifyOnIncident:           Bool = true
    var notifyOnConnectivityLoss:   Bool = true
    var notifyOnSignalDegradation:  Bool = false   // default off — too frequent
    var notifyOnRemediation:        Bool = true
    var notifyOnUpdateAvailable:    Bool = true

    // MARK: - Per-type cooldowns (seconds)

    private let typeCooldowns: [NetWatchNotificationType: TimeInterval] = [
        .incident:         300,     // 5 min
        .connectivityLoss:  60,     // 1 min
        .remediation:       30,     // 30s
        .updateAvailable: 86400,    // 1 day
    ]

    private var lastFired: [NetWatchNotificationType: Date] = [:]

    // MARK: - Permission

    func requestPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error {
                    print("[NetWatch] Notification permission error: \(error.localizedDescription)")
                }
            }
    }

    // MARK: - Incident notification

    /// Call from IncidentManager.bundleIncident() after writing the bundle.
    func notifyIncident(reason: String, subject: String) {
        guard isEnabled, notifyOnIncident else { return }
        guard canFire(.incident) else { return }
        markFired(.incident)

        let content          = UNMutableNotificationContent()
        content.title        = "NetWatch — \(reason)"
        content.body         = subject
        content.sound        = .default
        content.threadIdentifier = "netwatch.incident"

        fire(content, id: "netwatch.incident.\(UUID().uuidString)")
    }

    // MARK: - Connectivity loss notification

    /// Call from NetworkMonitorService when all ping targets fail.
    func notifyConnectivityLoss(failedTargets: [String]) {
        guard isEnabled, notifyOnConnectivityLoss else { return }
        guard canFire(.connectivityLoss) else { return }
        markFired(.connectivityLoss)

        let content          = UNMutableNotificationContent()
        content.title        = "NetWatch — Connectivity Loss"
        content.body         = failedTargets.count == 1
                               ? "No response from \(failedTargets[0])"
                               : "\(failedTargets.count) ping targets unreachable"
        content.sound        = .defaultCritical
        content.threadIdentifier = "netwatch.connectivity"

        fire(content, id: "netwatch.connectivity.\(UUID().uuidString)")
    }

    // MARK: - Remediation notification

    /// Call from RemediationEngine.log() when an action succeeds.
    /// Failed or info-level events are not surfaced as banners.
    func notifyRemediation(action: String, kind: RemediationKind, success: Bool) {
        guard isEnabled, notifyOnRemediation, success, kind != .info else { return }
        guard canFire(.remediation) else { return }
        markFired(.remediation)

        let content          = UNMutableNotificationContent()
        content.title        = "NetWatch — \(kind.rawValue)"
        content.body         = action
        content.sound        = .default
        content.threadIdentifier = "netwatch.remediation"

        fire(content, id: "netwatch.remediation.\(UUID().uuidString)")
    }

    // MARK: - Update available notification

    func notifyUpdateAvailable(version: String) {
        guard isEnabled, notifyOnUpdateAvailable else { return }
        guard canFire(.updateAvailable) else { return }
        markFired(.updateAvailable)

        let content          = UNMutableNotificationContent()
        content.title        = "NetWatch Update Available"
        content.body         = "Version \(version) is available. Check GitHub for the latest release."
        content.sound        = .default
        content.threadIdentifier = "netwatch.update"

        fire(content, id: "netwatch.update.\(UUID().uuidString)")
    }

    // MARK: - Test notification (bypasses all gates)

    func sendTest() {
        let content          = UNMutableNotificationContent()
        content.title        = "NetWatch Test"
        content.body         = "Notifications are working correctly."
        content.sound        = .default
        content.threadIdentifier = "netwatch.test"
        fire(content, id: "netwatch.test.\(UUID().uuidString)")
    }

    // MARK: - Private helpers

    private func canFire(_ type: NetWatchNotificationType) -> Bool {
        guard let cooldown = typeCooldowns[type] else { return true }
        guard let last     = lastFired[type]     else { return true }
        return Date().timeIntervalSince(last) >= cooldown
    }

    private func markFired(_ type: NetWatchNotificationType) {
        lastFired[type] = Date()
    }

    private func fire(_ content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[NetWatch] Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }
}
