/// BandwidthBudgetMonitor.swift — Weekly bandwidth budget tracking for NetWatch
///
/// Watches ConnectorSnapshot metrics from Firewalla and Nighthawk to estimate
/// current weekly bandwidth consumption, then fires webhook alerts when usage
/// crosses 80% or 100% of the configured budget.
///
/// Data sources (in priority order):
///   1. Nighthawk  — `week_rx_mb` + `week_tx_mb` (direct from router traffic meter)
///   2. Firewalla  — `top_bw_device` (approximate; Firewalla stores cumulative totals)
///
/// Alert thresholds:
///   80%  — warning
///   100% — critical (over budget)
///
/// Cooldown between alerts is configurable (default 24 hours).
///
/// Usage: instantiate once in NetworkMonitorService, call `check(snapshots:settings:)`
/// after each ConnectorManager poll cycle.

import Foundation

@MainActor
final class BandwidthBudgetMonitor: ObservableObject {

    // MARK: - Published state

    /// Estimated current weekly usage in GB across all connectors.
    @Published private(set) var weeklyUsageGB: Double = 0

    /// Fraction of budget consumed (0–1+). Nil if budget is disabled.
    @Published private(set) var budgetFraction: Double? = nil

    /// True if over budget.
    @Published private(set) var overBudget: Bool = false

    // MARK: - Alert state

    private var lastAlertTime: Date = .distantPast
    private var lastAlertedThreshold: Double = 0   // 0.8 or 1.0

    // MARK: - API

    /// Call after each ConnectorManager poll with the latest snapshots + current settings.
    func check(snapshots: [ConnectorSnapshot], settings: MonitorSettings) async {
        let budgetGB = settings.weeklyBandwidthBudgetGB
        guard budgetGB > 0 else {
            budgetFraction = nil
            overBudget     = false
            return
        }

        let usageGB = estimateWeeklyUsageGB(from: snapshots)
        weeklyUsageGB  = usageGB
        let fraction   = usageGB / budgetGB
        budgetFraction = fraction
        overBudget     = fraction >= 1.0

        // Alert logic
        let now          = Date()
        let cooldownSecs = settings.bandwidthAlertCooldownHours * 3_600
        let timeSinceLast = now.timeIntervalSince(lastAlertTime)
        guard timeSinceLast >= cooldownSecs, !settings.webhookURL.isEmpty else { return }

        let threshold: Double
        if fraction >= 1.0, lastAlertedThreshold < 1.0 {
            threshold = 1.0   // over budget — only alert if we haven't already alerted on this
        } else if fraction >= 0.8, lastAlertedThreshold < 0.8 {
            threshold = 0.8   // approaching budget
        } else {
            return   // nothing new to alert on
        }

        lastAlertTime          = now
        lastAlertedThreshold   = threshold

        await WebhookAlerter.sendBandwidthAlert(
            currentGB:  usageGB,
            budgetGB:   budgetGB,
            webhookURL: settings.webhookURL
        )
    }

    /// Reset the alert threshold tracker (call when the budget setting changes or at the
    /// start of a new week — Nighthawk resets its weekly counter each Monday).
    func resetAlertState() {
        lastAlertedThreshold = 0
        lastAlertTime = .distantPast
    }

    // MARK: - Estimation

    /// Estimates total weekly bandwidth in GB from the available connector data.
    private func estimateWeeklyUsageGB(from snapshots: [ConnectorSnapshot]) -> Double {
        var totalMB: Double = 0

        // Nighthawk — most accurate weekly counters (built into router traffic meter)
        if let nighthawk = snapshots.first(where: { $0.connectorId == "nighthawk" }) {
            let weekRX = nighthawk.metrics.first(where: { $0.key == "week_rx_mb" })?.value ?? 0
            let weekTX = nighthawk.metrics.first(where: { $0.key == "week_tx_mb" })?.value ?? 0
            if weekRX + weekTX > 0 {
                totalMB += weekRX + weekTX
            }
        }

        // Firewalla — if Nighthawk gave no data, use Firewalla's per-device totals
        // (these are cumulative from last reset, not strictly weekly — use as fallback)
        if totalMB == 0,
           let firewalla = snapshots.first(where: { $0.connectorId == "firewalla" }),
           let topBW = firewalla.metrics.first(where: { $0.key == "top_bw_device" }) {
            // top_bw_device is MB for the single top consumer; multiply by a rough
            // device-count factor to estimate total (conservative — better than nothing)
            let devCount = max(1.0, firewalla.metrics.first(where: { $0.key == "total_devices" })?.value ?? 1)
            let scaleFactor = min(5.0, devCount / 3.0)   // cap at 5× to avoid absurd estimates
            totalMB += topBW.value * scaleFactor
        }

        return totalMB / 1_024   // MB → GB
    }
}
