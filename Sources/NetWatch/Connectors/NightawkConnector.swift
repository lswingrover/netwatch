/// NightawkConnector.swift — NetWatch connector for Netgear Nighthawk routers
///
/// Uses the Netgear SOAP API that ships on most Nighthawk (and other Netgear)
/// routers. The service runs on port 5000 at the standard routerlogin address.
///
/// Prerequisites on your router:
///   1. Log in to http://routerlogin.net → Advanced → Administration
///   2. Ensure "Remote Management" is OFF (we use the LAN-side API only).
///   3. Note your admin password — that's the only credential needed.
///
/// SOAP endpoint: http://<router-ip>:5000/soap/server_sa/
/// Service URN:   urn:NETGEAR-ROUTER:service:DeviceInfo:1
///
/// Actions used:
///   GetInfo                   — firmware, model, serial, WAN IP
///   GetSystemInfo             — uptime, CPU, memory (some models)
///   GetTrafficMeterStatistics — per-day/week RX/TX byte totals
///   ETHConfigInfoGet          — port-level stats (some models)
///
/// Note: Netgear's SOAP API is model-specific. Actions that aren't supported
/// on a given model return a SOAP fault; the connector handles those gracefully.

import Foundation

final class NightawkConnector: DeviceConnector {

    // MARK: - Identity

    let id          = "nighthawk"
    let displayName = "Netgear Nighthawk"
    let iconName    = "wifi.router"

    // MARK: - State

    private(set) var config:       ConnectorConfig
    private(set) var isConnected:  Bool    = false
    private(set) var lastError:    String? = nil
    private(set) var lastSnapshot: ConnectorSnapshot? = nil

    // MARK: - Init

    init(config: ConnectorConfig = ConnectorConfig(id: "nighthawk")) {
        self.config = config
    }

    // MARK: - DeviceConnector

    func configure(_ config: ConnectorConfig) {
        self.config = config
    }

    func testConnection() async -> Result<String, Error> {
        do {
            let info = try await soapAction("GetInfo", service: "DeviceInfo")
            let model    = info["ModelName"]      ?? "Nighthawk"
            let firmware = info["Firmwareversion"] ?? "unknown"
            return .success("\(model) · FW \(firmware)")
        } catch {
            return .failure(error)
        }
    }

    func fetchSnapshot() async throws -> ConnectorSnapshot {
        // Fetch in parallel; tolerate partial failures (not all models support all actions)
        async let infoResult    = optionalSOAP("GetInfo",                   service: "DeviceInfo")
        async let trafficResult = optionalSOAP("GetTrafficMeterStatistics", service: "TrafficMeter")

        let (info, traffic) = await (infoResult, trafficResult)

        // ── Metrics ──────────────────────────────────────────────────────────

        var metrics: [ConnectorMetric] = []

        if let info {
            if let uptime = uptimeSeconds(from: info["Uptime"] ?? "") {
                metrics.append(ConnectorMetric(
                    key: "uptime_h", label: "Uptime",
                    value: uptime / 3600, unit: "h"))
            }
            if let wanIP = info["ExternalIPAddress"], !wanIP.isEmpty {
                // Record WAN IP as a labelled metric with value 0 — mainly for the summary
                metrics.append(ConnectorMetric(
                    key: "wan_ip", label: "WAN IP",
                    value: 0, unit: wanIP))
            }
            if let connState = info["ConnectionType"] {
                metrics.append(ConnectorMetric(
                    key: "conn_type", label: "Connection",
                    value: 0, unit: connState))
            }
        }

        if let traffic {
            // Traffic meter returns cumulative MB; report as-is
            if let rxStr = traffic["TodayDownload"], let rx = Double(rxStr) {
                metrics.append(ConnectorMetric(
                    key: "today_rx_mb", label: "Today RX",
                    value: rx, unit: "MB"))
            }
            if let txStr = traffic["TodayUpload"], let tx = Double(txStr) {
                metrics.append(ConnectorMetric(
                    key: "today_tx_mb", label: "Today TX",
                    value: tx, unit: "MB"))
            }
            if let weekRxStr = traffic["WeekDownload"], let weekRx = Double(weekRxStr) {
                metrics.append(ConnectorMetric(
                    key: "week_rx_mb", label: "Week RX",
                    value: weekRx, unit: "MB"))
            }
        }

        // ── Events ───────────────────────────────────────────────────────────

        var events: [ConnectorEvent] = []

        // If uptime < 5 min, flag a recent reboot
        if let uptimeMetric = metrics.first(where: { $0.key == "uptime_h" }),
           uptimeMetric.value < (5.0 / 60.0) {
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "reboot",
                description: "Router recently rebooted (uptime < 5 minutes)",
                severity: .warning))
        }

        // ── Summary ──────────────────────────────────────────────────────────

        let model    = info?["ModelName"] ?? "Nighthawk"
        let wanIP    = info?["ExternalIPAddress"] ?? "–"
        let todayRX  = metrics.first { $0.key == "today_rx_mb" }.map { String(format: "%.0f", $0.value) } ?? "–"
        let summary  = "\(model) · WAN \(wanIP) · Today RX \(todayRX) MB"

        let snapshot = ConnectorSnapshot(
            connectorId: id, connectorName: displayName,
            timestamp: Date(), metrics: metrics, events: events, summary: summary)

        isConnected  = true
        lastError    = nil
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: - SOAP

    private var soapURL: URL {
        let host = config.host.isEmpty ? "192.168.1.1" : config.host
        let port = config.port > 0 ? config.port : 5000
        return URL(string: "http://\(host):\(port)/soap/server_sa/")!
    }

    private var authHeader: String {
        let creds = "\(config.username.isEmpty ? "admin" : config.username):\(config.password)"
        let encoded = Data(creds.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    /// Execute a SOAP action and return the response body as a flat key→value dictionary.
    /// Parses the Netgear SOAP envelope (one level deep — enough for all used actions).
    private func soapAction(_ action: String, service: String) async throws -> [String: String] {
        let serviceURN = "urn:NETGEAR-ROUTER:service:\(service):1"
        let body = """
        <?xml version="1.0"?>
        <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
          <SOAP-ENV:Header>
            <SessionID>A7D88AE69687E58D9A00</SessionID>
          </SOAP-ENV:Header>
          <SOAP-ENV:Body>
            <M1:\(action) xmlns:M1="\(serviceURN)"/>
          </SOAP-ENV:Body>
        </SOAP-ENV:Envelope>
        """
        var req = URLRequest(url: soapURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\(serviceURN)#\(action)",       forHTTPHeaderField: "SOAPAction")
        req.setValue(authHeader,                       forHTTPHeaderField: "Authorization")
        req.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            isConnected = false
            lastError   = "HTTP \(code) for SOAP action \(action)"
            throw ConnectorError.httpError(code)
        }
        return parseSOAPResponse(data)
    }

    /// Same as `soapAction` but returns nil on any error (for optional capabilities).
    private func optionalSOAP(_ action: String, service: String) async -> [String: String]? {
        try? await soapAction(action, service: service)
    }

    /// Minimal SOAP response parser. Extracts leaf-node text values from the
    /// response body into a flat String→String dictionary.
    private func parseSOAPResponse(_ data: Data) -> [String: String] {
        guard let xml = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        // Match <TagName>value</TagName> patterns (Netgear responses are shallow)
        let pattern = #"<([A-Za-z][A-Za-z0-9_]*)>([^<]*)</\1>"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(xml.startIndex..., in: xml)
            for match in regex.matches(in: xml, range: range) {
                if let keyRange   = Range(match.range(at: 1), in: xml),
                   let valueRange = Range(match.range(at: 2), in: xml) {
                    let key   = String(xml[keyRange])
                    let value = String(xml[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    result[key] = value
                }
            }
        }
        return result
    }

    /// Parses Netgear uptime strings like "5 days 3 hours 22 minutes" → seconds.
    private func uptimeSeconds(from string: String) -> TimeInterval? {
        var total: TimeInterval = 0
        let units: [(String, TimeInterval)] = [
            ("day",    86400),
            ("hour",   3600),
            ("minute", 60),
            ("second", 1)
        ]
        let words = string.lowercased().components(separatedBy: .whitespaces)
        for (idx, word) in words.enumerated() {
            if let n = Double(word), idx + 1 < words.count {
                let unit = words[idx + 1]
                for (name, multiplier) in units where unit.hasPrefix(name) {
                    total += n * multiplier
                }
            }
        }
        return total > 0 ? total : nil
    }
}
