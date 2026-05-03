/// WebhookAlerter.swift — HTTP webhook alerting for NetWatch incidents
///
/// Supports two payload formats:
///
///   Slack Incoming Webhook  — detected when the URL contains "hooks.slack.com"
///   Generic JSON webhook    — any other URL receives a structured JSON object
///
/// Called from IncidentManager (on incident creation) and from
/// BandwidthBudgetMonitor (on budget threshold breach). Fire-and-forget:
/// errors are logged to stderr but never propagate to callers.
///
/// Usage:
///   await WebhookAlerter.sendIncident(
///       reason: "...", diagnosis: diagnosis, webhookURL: url)
///
///   await WebhookAlerter.sendBandwidthAlert(
///       currentGB: 85.3, budgetGB: 100.0, pct: 0.85, webhookURL: url)

import Foundation

enum WebhookAlerter {

    // MARK: - Public API

    /// Send an incident alert to the configured webhook.
    static func sendIncident(
        reason:      String,
        diagnosis:   StackDiagnosis?,
        webhookURL:  String
    ) async {
        guard !webhookURL.isEmpty, let url = URL(string: webhookURL) else { return }

        let healthScore = diagnosis?.healthScore ?? 0
        let rootCause   = diagnosis?.rootCause.rawValue ?? "unknown"
        let summary     = diagnosis?.summary ?? reason
        let recs        = diagnosis?.recommendations ?? []

        let payload: [String: Any]
        if webhookURL.contains("hooks.slack.com") {
            payload = slackIncidentPayload(reason: reason, healthScore: healthScore,
                                           rootCause: rootCause, summary: summary,
                                           recommendations: recs)
        } else {
            payload = genericIncidentPayload(reason: reason, healthScore: healthScore,
                                             rootCause: rootCause, summary: summary,
                                             recommendations: recs)
        }
        await post(payload: payload, to: url)
    }

    /// Send a bandwidth budget alert.
    static func sendBandwidthAlert(
        currentGB:  Double,
        budgetGB:   Double,
        webhookURL: String
    ) async {
        guard !webhookURL.isEmpty, let url = URL(string: webhookURL) else { return }
        let pct = budgetGB > 0 ? currentGB / budgetGB : 0

        let payload: [String: Any]
        if webhookURL.contains("hooks.slack.com") {
            payload = slackBandwidthPayload(currentGB: currentGB, budgetGB: budgetGB, pct: pct)
        } else {
            payload = genericBandwidthPayload(currentGB: currentGB, budgetGB: budgetGB, pct: pct)
        }
        await post(payload: payload, to: url)
    }

    // MARK: - Slack payloads

    private static func slackIncidentPayload(
        reason:          String,
        healthScore:     Int,
        rootCause:       String,
        summary:         String,
        recommendations: [String]
    ) -> [String: Any] {
        let scoreEmoji = healthScore >= 85 ? "🟢" : healthScore >= 60 ? "🟡" : healthScore >= 30 ? "🟠" : "🔴"
        var text = "\(scoreEmoji) *NetWatch Incident* — \(reason)\n"
        text    += "Health: *\(healthScore)/100* · Root cause: *\(rootCause)*\n"
        text    += summary
        if !recommendations.isEmpty {
            text += "\n*Recommendations:*\n" + recommendations.prefix(3).map { "• \($0)" }.joined(separator: "\n")
        }
        return ["text": text]
    }

    private static func slackBandwidthPayload(
        currentGB: Double,
        budgetGB:  Double,
        pct:       Double
    ) -> [String: Any] {
        let pctStr = String(format: "%.0f%%", pct * 100)
        let emoji  = pct >= 1.0 ? "🚨" : "⚠️"
        let text   = "\(emoji) *NetWatch Bandwidth Alert*\nUsage: *\(String(format: "%.1f", currentGB)) GB* of \(String(format: "%.0f", budgetGB)) GB weekly budget (\(pctStr))"
        return ["text": text]
    }

    // MARK: - Generic JSON payloads

    private static func genericIncidentPayload(
        reason:          String,
        healthScore:     Int,
        rootCause:       String,
        summary:         String,
        recommendations: [String]
    ) -> [String: Any] {
        [
            "type":            "netwatch_incident",
            "timestamp":       ISO8601DateFormatter().string(from: Date()),
            "reason":          reason,
            "health_score":    healthScore,
            "root_cause":      rootCause,
            "summary":         summary,
            "recommendations": recommendations
        ]
    }

    private static func genericBandwidthPayload(
        currentGB: Double,
        budgetGB:  Double,
        pct:       Double
    ) -> [String: Any] {
        [
            "type":           "netwatch_bandwidth_alert",
            "timestamp":      ISO8601DateFormatter().string(from: Date()),
            "current_gb":     currentGB,
            "budget_gb":      budgetGB,
            "percent_used":   pct,
            "over_budget":    currentGB >= budgetGB
        ]
    }

    // MARK: - HTTP POST

    private static func post(payload: [String: Any], to url: URL) async {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.httpBody    = body
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("NetWatch/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                fputs("[WebhookAlerter] HTTP \(http.statusCode) posting to \(url)\n", stderr)
            }
        } catch {
            fputs("[WebhookAlerter] \(error.localizedDescription)\n", stderr)
        }
    }
}
