/// OrbiConnector.swift — NetWatch connector for Netgear Orbi mesh systems
///
/// Uses the Netgear SOAP API on HTTPS/443. Tested on RBRE960 firmware V7.2.8.2.
///
/// Auth flow (firmware ≥ v7 / LoginMethod=2.0):
///   1. POST SOAPLogin to DeviceConfig:1 with Username + Password
///   2. Capture `Set-Cookie: sess_id=...` from the response
///   3. Include that cookie in all subsequent SOAP requests
///
/// Key differences from older Nighthawk / HTTP-5000 connectors:
///   - Content-Type must be `multipart/form-data` (not `text/xml`)
///   - SOAP envelope namespace declarations differ slightly
///   - Traffic meter lives in DeviceConfig:1, NOT in a TrafficMeter service
///   - WAN IP is in WANIPConnection:1#GetInfo (key: NewExternalIPAddress)
///
/// SOAP endpoint: https://<orbi-ip>/soap/server_sa/

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

    /// Session cookie obtained from SOAPLogin. Cleared on auth error.
    private var sessionCookie: String? = nil

    // MARK: - Init

    init(config: ConnectorConfig = ConnectorConfig(id: "orbi")) {
        self.config = config
    }

    // MARK: - DeviceConnector

    func configure(_ config: ConnectorConfig) {
        self.config  = config
        sessionCookie = nil   // force re-login on config change
    }

    func testConnection() async -> Result<String, Error> {
        do {
            try await ensureLoggedIn()
            let info = try await soapAction("GetInfo", service: "DeviceInfo:1")
            let model    = info["ModelName"]      ?? "Orbi"
            let firmware = info["Firmwareversion"] ?? info["FirmwareVersion"] ?? "unknown"
            return .success("\(model) · FW \(firmware)")
        } catch {
            return .failure(error)
        }
    }

    func fetchSnapshot() async throws -> ConnectorSnapshot {
        try await ensureLoggedIn()

        // Fetch in parallel; tolerate partial failures
        async let infoResult    = optionalSOAP("GetInfo",                    service: "DeviceInfo:1")
        async let wanResult     = optionalSOAP("GetInfo",                    service: "WANIPConnection:1")
        async let trafficResult = optionalSOAP("GetTrafficMeterStatistics",  service: "DeviceConfig:1")
        async let sysResult     = optionalSOAP("GetSystemInfo",              service: "DeviceInfo:1")

        let (info, wan, traffic, sys) = await (infoResult, wanResult, trafficResult, sysResult)

        // ── Metrics ──────────────────────────────────────────────────────────

        var metrics: [ConnectorMetric] = []

        if let wan {
            if let wanIP = wan["NewExternalIPAddress"], !wanIP.isEmpty {
                metrics.append(ConnectorMetric(
                    key: "wan_ip", label: "WAN IP",
                    value: 0, unit: wanIP))
            }
            if let connType = wan["NewConnectionType"] ?? wan["NewAddressingType"] {
                metrics.append(ConnectorMetric(
                    key: "conn_type", label: "Connection",
                    value: 0, unit: connType))
            }
            // WANIPConnection Enable = 1 means WAN is up
            if let enable = wan["NewEnable"] {
                let up  = enable == "1"
                let sev: MetricSeverity = up ? .ok : .warning
                metrics.append(ConnectorMetric(
                    key: "wan_status", label: "WAN Status",
                    value: 0, unit: up ? "Connected" : "Disconnected", severity: sev))
            }
        }

        if let traffic {
            // Traffic meter stores doubles in "X.XX" format; some fields use "X.XX/X.XX"
            func mb(_ raw: String?) -> Double? {
                guard let s = raw?.components(separatedBy: "/").first else { return nil }
                return Double(s.trimmingCharacters(in: .whitespaces))
            }
            if let rx = mb(traffic["NewTodayDownload"]) {
                metrics.append(ConnectorMetric(
                    key: "today_rx_mb", label: "Today RX",
                    value: rx, unit: "MB"))
            }
            if let tx = mb(traffic["NewTodayUpload"]) {
                metrics.append(ConnectorMetric(
                    key: "today_tx_mb", label: "Today TX",
                    value: tx, unit: "MB"))
            }
            if let weekRx = mb(traffic["NewWeekDownload"]) {
                metrics.append(ConnectorMetric(
                    key: "week_rx_mb", label: "Week RX",
                    value: weekRx, unit: "MB"))
            }
            if let weekTx = mb(traffic["NewWeekUpload"]) {
                metrics.append(ConnectorMetric(
                    key: "week_tx_mb", label: "Week TX",
                    value: weekTx, unit: "MB"))
            }
        }

        if let sys {
            if let cpuStr = sys["NewCPUUtilization"], let cpu = Double(cpuStr) {
                let sev: MetricSeverity = cpu > 90 ? .warning : .ok
                metrics.append(ConnectorMetric(
                    key: "cpu_pct", label: "CPU",
                    value: cpu, unit: "%", severity: sev))
            }
            if let memStr = sys["NewMemoryUtilization"], let mem = Double(memStr) {
                let sev: MetricSeverity = mem > 85 ? .warning : .ok
                metrics.append(ConnectorMetric(
                    key: "mem_pct", label: "Memory",
                    value: mem, unit: "%", severity: sev))
            }
        }

        // ── Events ───────────────────────────────────────────────────────────

        var events: [ConnectorEvent] = []

        // Flag if WAN is down
        if let statusMetric = metrics.first(where: { $0.key == "wan_status" }),
           statusMetric.severity == .warning {
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "wan_down",
                description: "WAN status: \(statusMetric.unit)",
                severity: .critical))
        }

        // Flag high CPU
        if let cpuMetric = metrics.first(where: { $0.key == "cpu_pct" }),
           cpuMetric.severity == .warning {
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "high_cpu",
                description: "Orbi CPU at \(Int(cpuMetric.value))%",
                severity: .warning))
        }

        // ── Summary ──────────────────────────────────────────────────────────

        let model   = info?["ModelName"] ?? "Orbi"
        let wanIP   = metrics.first(where: { $0.key == "wan_ip"      })?.unit ?? "–"
        let todayRX = metrics.first(where: { $0.key == "today_rx_mb" })
                             .map { String(format: "%.0f", $0.value) } ?? "–"
        let summary = "\(model) · WAN \(wanIP) · Today RX \(todayRX) MB"

        let snapshot = ConnectorSnapshot(
            connectorId: id, connectorName: displayName,
            timestamp: Date(), metrics: metrics, events: events, summary: summary)

        isConnected  = true
        lastError    = nil
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: - Auth

    /// Ensure we have a valid session cookie. Calls SOAPLogin if needed.
    private func ensureLoggedIn() async throws {
        guard sessionCookie == nil else { return }

        let serviceURN = "urn:NETGEAR-ROUTER:service:DeviceConfig:1"
        let user = config.username.isEmpty ? "admin" : config.username

        let body = soapEnvelope(action: "SOAPLogin", serviceURN: serviceURN,
                                 params: "<Username>\(user)</Username>\n<Password>\(config.password)</Password>")

        var req = URLRequest(url: soapURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("multipart/form-data",                  forHTTPHeaderField: "Content-Type")
        req.setValue("\(serviceURN)#SOAPLogin",              forHTTPHeaderField: "SOAPAction")
        req.setValue("pynetgear",                             forHTTPHeaderField: "User-Agent")
        req.setValue("no-cache",                              forHTTPHeaderField: "Cache-Control")
        req.httpBody = Data(body.utf8)

        let (_, response) = try await selfSignedSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.httpError(0)
        }
        guard http.statusCode == 200 else {
            isConnected = false
            throw ConnectorError.httpError(http.statusCode)
        }

        // Extract the session cookie
        let allHeaders = http.allHeaderFields
        if let setCookie = allHeaders["Set-Cookie"] as? String {
            // Keep only the sess_id=... portion (strip SameSite/HttpOnly flags)
            let cookieVal = setCookie.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if !cookieVal.isEmpty {
                sessionCookie = cookieVal
                return
            }
        }
        // Some URLSession implementations coalesce Set-Cookie
        // fallback: look for sess_id in any header
        for (key, value) in allHeaders {
            if let k = key as? String, k.lowercased() == "set-cookie",
               let v = value as? String, v.hasPrefix("sess_id=") {
                sessionCookie = v.components(separatedBy: ";").first
                return
            }
        }

        throw ConnectorError.parseError("SOAPLogin succeeded (HTTP 200) but no Set-Cookie header")
    }

    // MARK: - SOAP

    private var soapURL: URL {
        let host = config.host.isEmpty ? "192.168.40.161" : config.host
        let port = config.port > 0 ? config.port : 443
        return URL(string: "https://\(host):\(port)/soap/server_sa/")!
    }

    /// Build the SOAP envelope in pynetgear's format (different namespace declarations
    /// from the standard that Netgear v7 firmware actually accepts).
    private func soapEnvelope(action: String, serviceURN: String, params: String) -> String {
        return """
        <?xml version="1.0" encoding="utf-8" standalone="no"?>
        <SOAP-ENV:Envelope xmlns:SOAPSDK1="http://www.w3.org/2001/XMLSchema"
          xmlns:SOAPSDK2="http://www.w3.org/2001/XMLSchema-instance"
          xmlns:SOAPSDK3="http://schemas.xmlsoap.org/soap/encoding/"
          xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
        <SOAP-ENV:Header>
        <SessionID>A7D88AE69687E58D9A00</SessionID>
        </SOAP-ENV:Header>
        <SOAP-ENV:Body>
        <M1:\(action) xmlns:M1="\(serviceURN)">
        \(params)</M1:\(action)>
        </SOAP-ENV:Body>
        </SOAP-ENV:Envelope>
        """
    }

    private func soapAction(_ action: String, service: String) async throws -> [String: String] {
        let serviceURN = "urn:NETGEAR-ROUTER:service:\(service)"
        let body = soapEnvelope(action: action, serviceURN: serviceURN, params: "")

        var req = URLRequest(url: soapURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 7
        req.setValue("multipart/form-data",          forHTTPHeaderField: "Content-Type")
        req.setValue("\(serviceURN)#\(action)",       forHTTPHeaderField: "SOAPAction")
        req.setValue("pynetgear",                      forHTTPHeaderField: "User-Agent")
        req.setValue("no-cache",                       forHTTPHeaderField: "Cache-Control")
        if let cookie = sessionCookie {
            req.setValue(cookie,                       forHTTPHeaderField: "Cookie")
        }
        req.httpBody = Data(body.utf8)

        let (data, response) = try await selfSignedSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            isConnected = false
            lastError   = "HTTP \(code) for SOAP action \(action)"
            throw ConnectorError.httpError(code)
        }

        let parsed = parseSOAPResponse(data)

        // A SOAP body ResponseCode 401 means our session expired → invalidate + retry once
        if parsed["ResponseCode"] == "401" {
            sessionCookie = nil
            isConnected   = false
            lastError     = "Session expired (SOAP 401)"
            throw ConnectorError.parseError("SOAP session expired — will re-login on next poll")
        }

        return parsed
    }

    private func optionalSOAP(_ action: String, service: String) async -> [String: String]? {
        try? await soapAction(action, service: service)
    }

    /// Flat XML leaf-node parser — handles Netgear's single-level SOAP responses.
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

    // MARK: - Self-signed TLS

    private lazy var selfSignedSession: URLSession = {
        // Disable automatic cookie storage so Set-Cookie headers remain
        // visible in HTTPURLResponse.allHeaderFields — otherwise URLSession
        // silently consumes them before we can extract the sess_id value.
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies   = false
        return URLSession(configuration: config,
                          delegate: SelfSignedDelegate(),
                          delegateQueue: nil)
    }()
}

// MARK: - Self-Signed Certificate Delegate

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
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
