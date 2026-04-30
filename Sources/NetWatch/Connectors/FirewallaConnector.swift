/// FirewallaConnector.swift — NetWatch connector for Firewalla Gold/Purple/Blue+
///
/// Talks to the Firewalla local REST API running on port 8833 of your Firewalla
/// device. Authentication uses a "box token" — a static bearer token you copy
/// from the Firewalla mobile app (More → Settings → API Access → Box API Token).
///
/// API reference: https://firewalla.com/products/firewalla-gold-plus
/// Community docs: https://github.com/firewalla/firewalla (API section)
///
/// Endpoints used:
///   GET /v1/stats/summary     — bandwidth + session counts
///   GET /v1/alarms/active     — active security alarms / blocks
///   GET /v1/flows?count=5     — most recent flows (top-N for context)
///   GET /v1/host/status       — device CPU/memory/uptime

import Foundation

final class FirewallaConnector: DeviceConnector {

    // MARK: - Identity

    let id          = "firewalla"
    let displayName = "Firewalla"
    let iconName    = "shield.lefthalf.filled"

    // MARK: - State

    private(set) var config:       ConnectorConfig
    private(set) var isConnected:  Bool    = false
    private(set) var lastError:    String? = nil
    private(set) var lastSnapshot: ConnectorSnapshot? = nil

    // MARK: - Init

    init(config: ConnectorConfig = ConnectorConfig(id: "firewalla")) {
        self.config = config
    }

    // MARK: - DeviceConnector

    func configure(_ config: ConnectorConfig) {
        self.config = config
    }

    func testConnection() async -> Result<String, Error> {
        do {
            let data = try await get("/v1/host/status")
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let model   = json?["model"]        as? String ?? "Firewalla"
            let version = json?["releaseTarget"] as? String ?? "unknown"
            return .success("\(model) · firmware \(version)")
        } catch {
            return .failure(error)
        }
    }

    func fetchSnapshot() async throws -> ConnectorSnapshot {
        async let statsData  = get("/v1/stats/summary")
        async let alarmsData = get("/v1/alarms/active")
        async let hostData   = get("/v1/host/status")

        let (stats, alarms, host) = try await (statsData, alarmsData, hostData)

        let statsJSON  = (try? JSONSerialization.jsonObject(with: stats))  as? [String: Any] ?? [:]
        let alarmsJSON = (try? JSONSerialization.jsonObject(with: alarms)) as? [[String: Any]] ?? []
        let hostJSON   = (try? JSONSerialization.jsonObject(with: host))   as? [String: Any] ?? [:]

        // ── Metrics ──────────────────────────────────────────────────────────

        var metrics: [ConnectorMetric] = []

        // Bandwidth (stats summary returns bytes/s — convert to Mbps)
        if let bytesIn  = statsJSON["bytesIn"]  as? Double {
            metrics.append(ConnectorMetric(
                key: "wan_rx_mbps", label: "WAN RX",
                value: (bytesIn * 8) / 1_000_000, unit: "Mbps",
                severity: bytesIn > 100_000_000 ? .warning : .ok))
        }
        if let bytesOut = statsJSON["bytesOut"] as? Double {
            metrics.append(ConnectorMetric(
                key: "wan_tx_mbps", label: "WAN TX",
                value: (bytesOut * 8) / 1_000_000, unit: "Mbps"))
        }

        // Active sessions / flows
        if let sessions = statsJSON["activeSessions"] as? Double {
            metrics.append(ConnectorMetric(
                key: "active_sessions", label: "Active Sessions",
                value: sessions, unit: ""))
        }

        // Host: CPU & memory
        if let cpu = hostJSON["cpuUsage"] as? Double {
            metrics.append(ConnectorMetric(
                key: "cpu_pct", label: "CPU",
                value: cpu * 100, unit: "%",
                severity: cpu > 0.85 ? .warning : .ok))
        }
        if let mem = hostJSON["memUsage"] as? Double {
            metrics.append(ConnectorMetric(
                key: "mem_pct", label: "Memory",
                value: mem * 100, unit: "%",
                severity: mem > 0.90 ? .warning : .ok))
        }
        if let uptime = hostJSON["uptime"] as? Double {
            metrics.append(ConnectorMetric(
                key: "uptime_h", label: "Uptime",
                value: uptime / 3600, unit: "h"))
        }

        // Alarm count
        let alarmCount = Double(alarmsJSON.count)
        metrics.append(ConnectorMetric(
            key: "active_alarms", label: "Active Alarms",
            value: alarmCount, unit: "",
            severity: alarmCount > 0 ? .warning : .ok))

        // ── Events ───────────────────────────────────────────────────────────

        var events: [ConnectorEvent] = []
        for alarm in alarmsJSON.prefix(10) {
            let ts  = (alarm["ts"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let msg = alarm["message"] as? String ?? alarm["type"] as? String ?? "Unknown alarm"
            let sev = (alarm["severity"] as? String == "high") ? MetricSeverity.critical : .warning
            events.append(ConnectorEvent(
                timestamp: ts, type: "alarm",
                description: msg, severity: sev))
        }

        // ── Summary ──────────────────────────────────────────────────────────

        let model    = hostJSON["model"]  as? String ?? "Firewalla"
        let rxMbps   = metrics.first { $0.key == "wan_rx_mbps" }?.value ?? 0
        let txMbps   = metrics.first { $0.key == "wan_tx_mbps" }?.value ?? 0
        let summary  = "\(model) — RX \(String(format: "%.1f", rxMbps)) Mbps / TX \(String(format: "%.1f", txMbps)) Mbps · \(alarmsJSON.count) active alarm(s)"

        let snapshot = ConnectorSnapshot(
            connectorId: id, connectorName: displayName,
            timestamp: Date(), metrics: metrics, events: events, summary: summary)

        isConnected  = true
        lastError    = nil
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: - HTTP

    /// Effective base URL, defaulting to port 8833.
    private var baseURL: URL {
        let host = config.host.isEmpty ? "192.168.1.1" : config.host
        let port = config.port > 0 ? config.port : 8833
        return URL(string: "http://\(host):\(port)")!
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 10
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            isConnected = false
            lastError   = "HTTP \(code) from \(path)"
            throw ConnectorError.httpError(code)
        }
        return data
    }
}

// MARK: - Errors

enum ConnectorError: Error, LocalizedError {
    case httpError(Int)
    case missingConfig(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):      return "HTTP error \(code)"
        case .missingConfig(let field): return "Missing config: \(field)"
        case .parseError(let detail):   return "Parse error: \(detail)"
        }
    }
}
