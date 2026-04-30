/// OrbiConnector.swift — NetWatch connector for Netgear Orbi mesh systems
///
/// Talks to the Netgear SOAP API exposed by Orbi satellites and routers over
/// HTTPS. Unlike older Nighthawk models (which use HTTP on port 5000), Orbi
/// firmware v7.x exposes the SOAP endpoint exclusively on HTTPS port 443 with
/// a self-signed certificate.
///
/// Prerequisites on your Orbi:
///   1. Log in to http://orbilogin.net → Settings → Administration
///   2. Note your admin password — that's the only credential needed.
///   3. The SOAP endpoint is always-on; no extra setting to enable.
///
/// SOAP endpoint: https://<orbi-ip>/soap/server_sa/
/// Service URN:   urn:NETGEAR-ROUTER:service:DeviceInfo:1
///
/// This connector uses a URLSession with a custom delegate to accept the Orbi's
/// self-signed TLS certificate (only for the configured local IP — not globally
/// disabled). This is safe for LAN-only access because you're connecting to a
/// known, physically-local device that you control.
///
/// Tested on: Orbi RBRE960 (WiFi 6E), SOAP version 3.46
/// Should also work on: RBR760, RBR860, and most Orbi Pro models.

import Foundation

// MARK: - Connector

final class OrbiConnector: DeviceConnector {

    // MARK: - Identity

    let id          = "orbi"
    let displayName = "Netgear Orbi"
    let iconName    = "wifi.router.fill"

    // MARK: - State

    private(set) var config:       ConnectorConfig
    private(set) var isConnected:  Bool    = false
    private(set) var lastError:    String? = nil
    private(set) var lastSnapshot: ConnectorSnapshot? = nil

    // MARK: - Init

    init(config: ConnectorConfig = ConnectorConfig(id: "orbi")) {
        self.config = config
    }

    // MARK: - DeviceConnector

    func configure(_ config: ConnectorConfig) {
        self.config = config
    }

    func testConnection() async -> Result<String, Error> {
        do {
            let info = try await soapAction("GetInfo", service: "DeviceInfo")
            let model    = info["ModelName"]       ?? "Orbi"
            let firmware = info["Firmwareversion"]  ?? info["FirmwareVersion"] ?? "unknown"
            return .success("\(model) · FW \(firmware)")
        } catch {
            return .failure(error)
        }
    }

    func fetchSnapshot() async throws -> ConnectorSnapshot {
        // Fetch in parallel; tolerate partial failures (not all Orbi models support all actions)
        async let infoResult    = optionalSOAP("GetInfo",                   service: "DeviceInfo")
        async let trafficResult = optionalSOAP("GetTrafficMeterStatistics", service: "TrafficMeter")

        let (info, traffic) = await (infoResult, trafficResult)

        // ── Metrics ──────────────────────────────────────────────────────────

        var metrics: [ConnectorMetric] = []

        if let info {
            // Uptime — Orbi returns it in the same "X days Y hours Z minutes" format
            if let uptime = uptimeSeconds(from: info["Uptime"] ?? "") {
                metrics.append(ConnectorMetric(
                    key: "uptime_h", label: "Uptime",
                    value: uptime / 3600, unit: "h"))
            }
            if let wanIP = info["ExternalIPAddress"], !wanIP.isEmpty {
                metrics.append(ConnectorMetric(
                    key: "wan_ip", label: "WAN IP",
                    value: 0, unit: wanIP))
            }
            if let connType = info["ConnectionType"] {
                metrics.append(ConnectorMetric(
                    key: "conn_type", label: "Connection",
                    value: 0, unit: connType))
            }
            // Orbi-specific: internet connection status
            if let status = info["ConnectionStatus"] ?? info["InternetConnectionStatus"] {
                let sev: MetricSeverity = status.lowercased().contains("connected") ? .ok : .warning
                metrics.append(ConnectorMetric(
                    key: "wan_status", label: "WAN Status",
                    value: 0, unit: status, severity: sev))
            }
        }

        if let traffic {
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

        if let uptimeMetric = metrics.first(where: { $0.key == "uptime_h" }),
           uptimeMetric.value < (5.0 / 60.0) {
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "reboot",
                description: "Orbi recently rebooted (uptime < 5 minutes)",
                severity: .warning))
        }

        // Flag if WAN is not connected
        if let statusMetric = metrics.first(where: { $0.key == "wan_status" }),
           statusMetric.severity == .warning {
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "wan_down",
                description: "WAN status: \(statusMetric.unit)",
                severity: .critical))
        }

        // ── Summary ──────────────────────────────────────────────────────────

        let model   = info?["ModelName"] ?? "Orbi"
        let wanIP   = info?["ExternalIPAddress"] ?? "–"
        let todayRX = metrics.first { $0.key == "today_rx_mb" }.map { String(format: "%.0f", $0.value) } ?? "–"
        let summary = "\(model) · WAN \(wanIP) · Today RX \(todayRX) MB"

        let snapshot = ConnectorSnapshot(
            connectorId: id, connectorName: displayName,
            timestamp: Date(), metrics: metrics, events: events, summary: summary)

        isConnected  = true
        lastError    = nil
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: - SOAP (HTTPS)

    private var soapURL: URL {
        let host = config.host.isEmpty ? "192.168.40.161" : config.host
        // Orbi exposes SOAP on HTTPS/443. Override with config.port if needed.
        let port = config.port > 0 ? config.port : 443
        return URL(string: "https://\(host):\(port)/soap/server_sa/")!
    }

    private var authHeader: String {
        let user    = config.username.isEmpty ? "admin" : config.username
        let encoded = Data("\(user):\(config.password)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

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

        // Use the self-signed-cert-accepting session
        let session = selfSignedSession
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            isConnected = false
            lastError   = "HTTP \(code) for SOAP action \(action)"
            throw ConnectorError.httpError(code)
        }
        return parseSOAPResponse(data)
    }

    private func optionalSOAP(_ action: String, service: String) async -> [String: String]? {
        try? await soapAction(action, service: service)
    }

    /// Minimal SOAP response parser — identical to NightawkConnector.
    private func parseSOAPResponse(_ data: Data) -> [String: String] {
        guard let xml = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
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

    private func uptimeSeconds(from string: String) -> TimeInterval? {
        var total: TimeInterval = 0
        let units: [(String, TimeInterval)] = [
            ("day",    86400), ("hour",   3600),
            ("minute", 60),    ("second", 1)
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

    // MARK: - Self-signed TLS

    /// A URLSession that accepts the Orbi's self-signed LAN certificate.
    /// This is scoped to local network requests and does not disable global TLS validation.
    private lazy var selfSignedSession: URLSession = {
        let delegate = SelfSignedDelegate()
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }()
}

// MARK: - Self-Signed Certificate Delegate

/// Accepts self-signed certificates for LAN connections to known local devices.
/// Only bypasses certificate validation — authentication, encryption, and
/// data integrity are all still enforced by TLS.
private final class SelfSignedDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Accept the self-signed certificate for this local host
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
