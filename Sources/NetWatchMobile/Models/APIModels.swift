/// APIModels.swift — Codable structs matching NetWatch Mac API JSON responses
///
/// These mirror the payload types in NetWatchAPIServer.swift on the Mac side.
/// Keep both files in sync when extending the API.

import Foundation

// MARK: - Health

struct APIHealthPayload: Codable {
    let score:     Int
    let status:    String     // "healthy" | "degraded" | "critical"
    let timestamp: String
    let layers:    [String: String]

    var statusColor: HealthStatusColor {
        switch status {
        case "healthy":  return .green
        case "degraded": return .yellow
        default:         return .red
        }
    }

    /// Human-readable status label.
    var statusLabel: String {
        switch status {
        case "healthy":  return "Healthy"
        case "degraded": return "Degraded"
        default:         return "Critical"
        }
    }
}

enum HealthStatusColor { case green, yellow, red }

// MARK: - Connectors

struct APIConnectorPayload: Codable, Identifiable {
    let id:          String
    let name:        String
    let connected:   Bool
    let lastUpdated: String?
    let summary:     String?
    let error:       String?
    let metrics:     [APIMetric]
    let events:      [APIEvent]

    /// Most recent event (if any).
    var latestEvent: APIEvent? { events.first }

    /// Critical metric count.
    var criticalCount: Int { metrics.filter { $0.severity == "critical" }.count }
    var warningCount:  Int { metrics.filter { $0.severity == "warning"  }.count }
}

struct APIMetric: Codable, Identifiable {
    var id: String { key }
    let key:      String
    let label:    String
    let value:    Double
    let unit:     String
    let severity: String   // "ok" | "info" | "warning" | "critical" | "unknown"

    var severityIcon: String {
        switch severity {
        case "critical": return "exclamationmark.triangle.fill"
        case "warning":  return "exclamationmark.triangle"
        case "ok":       return "checkmark.circle.fill"
        case "info":     return "info.circle.fill"
        default:         return "questionmark.circle"
        }
    }

    var formattedValue: String { "\(value.formatted()) \(unit)" }
}

struct APIEvent: Codable, Identifiable {
    var id: String { timestamp + type }
    let timestamp:   String
    let type:        String
    let description: String
    let severity:    String

    var parsedDate: Date? {
        ISO8601DateFormatter().date(from: timestamp)
    }

    var timeAgoString: String {
        guard let date = parsedDate else { return timestamp }
        let delta = -date.timeIntervalSinceNow
        if delta < 60    { return "Just now" }
        if delta < 3600  { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        return "\(Int(delta / 86400))d ago"
    }
}

// MARK: - Status

struct APIStatusPayload: Codable {
    let macPublicIP:   String
    let macLocalIP:    String
    let wifiSSID:      String
    let gatewayRTT:    Double?
    let isMonitoring:  Bool
    let appVersion:    String

    var gatewayRTTFormatted: String {
        guard let rtt = gatewayRTT else { return "–" }
        return String(format: "%.1f ms", rtt)
    }
}

// MARK: - Incidents

struct APIIncidentSummary: Codable, Identifiable {
    let id:          String
    let timestamp:   String
    let healthScore: Int
    let rootCause:   String
    let severity:    String

    var parsedDate: Date? {
        ISO8601DateFormatter().date(from: timestamp)
    }

    var formattedDate: String {
        guard let date = parsedDate else { return timestamp }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: date)
    }

    var timeAgoString: String {
        guard let date = parsedDate else { return "" }
        let delta = -date.timeIntervalSinceNow
        if delta < 60    { return "Just now" }
        if delta < 3600  { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        return "\(Int(delta / 86400))d ago"
    }

    var severityIcon: String {
        switch severity {
        case "critical": return "exclamationmark.triangle.fill"
        case "warning":  return "exclamationmark.triangle"
        default:         return "info.circle"
        }
    }
}
