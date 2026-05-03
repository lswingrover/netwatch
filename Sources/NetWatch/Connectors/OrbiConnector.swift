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

// MARK: - Data models

struct OrbiSatellite: Identifiable, Equatable {
    var id: String { mac }
    let mac:          String
    let name:         String
    let ip:           String
    let backhaulBand: String   // "5", "6", or "" = wired/unknown
    let clientCount:  Int
    let isOnline:     Bool

    var backhaulLabel: String {
        if backhaulBand.contains("6") { return "6 GHz" }
        if backhaulBand.contains("5") { return "5 GHz" }
        if backhaulBand == "eth" || backhaulBand == "wired" { return "Wired" }
        return backhaulBand.isEmpty ? "Wireless" : backhaulBand
    }
    var backhaulIcon: String {
        if backhaulBand == "eth" || backhaulBand == "wired" { return "cable.connector.horizontal" }
        if backhaulBand.contains("6") { return "wifi" }
        return "wifi"
    }
}

struct OrbiRouterSummary {
    var model:        String = "Orbi"
    var firmware:     String = ""
    var wanIP:        String = ""
    var wanStatus:    String = ""
    var wanConnected: Bool   = false
    var cpuPct:       Double?
    var memPct:       Double?
    var totalClients: Int    = 0
    var todayRXmb:    Double?
    var todayTXmb:    Double?
    var weekRXmb:     Double?
    var guestEnabled: Bool   = false
    var firmwareUpdate: String = ""   // non-empty = update available
}

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

    /// Parsed satellite node list from last successful snapshot.
    private(set) var lastSatellites: [OrbiSatellite] = []

    /// Parsed router summary from last successful snapshot.
    private(set) var lastRouterSummary: OrbiRouterSummary = OrbiRouterSummary()

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
        async let infoResult       = optionalSOAP("GetInfo",                    service: "DeviceInfo:1")
        async let wanResult        = optionalSOAP("GetInfo",                    service: "WANIPConnection:1")
        async let trafficResult    = optionalSOAP("GetTrafficMeterStatistics",  service: "DeviceConfig:1")
        async let sysResult        = optionalSOAP("GetSystemInfo",              service: "DeviceInfo:1")
        async let rawAttach2Result = optionalRawSOAP("GetAttachDevice2",        service: "DeviceInfo:1")
        async let guestResult      = optionalSOAP("GetGuestAccessEnabled",      service: "WLANConfiguration:1")
        async let newFWResult      = optionalSOAP("GetNewFirmware",             service: "DeviceConfig:1")

        let (info, wan, traffic, sys, rawAttach2, guest, newFW) = await (
            infoResult, wanResult, trafficResult, sysResult,
            rawAttach2Result, guestResult, newFWResult
        )

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
            if let cpuStr = sys["NewCPUUtilization"], let cpu = Double(cpuStr),
               cpu < 100 {   // 100 is a firmware sentinel meaning "not available" on RBRE960
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

        // ── Connected clients + satellite nodes ───────────────────────────────
        // V7 firmware (RBRE960) GetAttachDevice2 returns structured XML <Device> blocks,
        // NOT the older pipe/at-delimited format. We fetch the raw XML and parse it directly.
        //
        // Satellite detection: satellite nodes don't appear as Device entries. Instead,
        // each device has a <ConnAPMAC> field with the MAC of the AP it's connected to.
        // Multiple unique ConnAPMAC values = multiple AP nodes (router + N satellites).

        var totalClients  = 0
        var clients24G    = 0
        var clients5G     = 0
        var clients6G     = 0
        var parsedSats:   [OrbiSatellite] = []

        // Parse <Device> blocks from raw GetAttachDevice2 XML
        let deviceBlocks = parseDeviceBlocks(rawAttach2 ?? "")

        // Collect unique AP MACs so we can infer satellite count
        var apMacClientCount: [String: Int] = [:]   // AP MAC → number of clients on it
        var apMacSample:      [String: (name: String, band: String)] = [:]

        for dev in deviceBlocks {
            let connAP = (dev["ConnAPMAC"] ?? "").uppercased()
            let conn   = dev["ConnectionType"] ?? ""
            let name   = dev["Name"] ?? dev["MAC"] ?? "Unknown"
            let connLower = conn.lowercased()

            totalClients += 1
            if connLower.contains("2.4")  { clients24G += 1 }
            else if connLower.contains("6") { clients6G += 1 }
            else if connLower.contains("5") { clients5G += 1 }

            if !connAP.isEmpty {
                apMacClientCount[connAP, default: 0] += 1
                if apMacSample[connAP] == nil {
                    apMacSample[connAP] = (name: name, band: connLower)
                }
            }
        }

        // Each unique ConnAPMAC is an AP node (router or satellite).
        // The router is the node with the most clients OR with 6 GHz clients (heuristic).
        // We label the non-router APs as satellites, ordered by client count descending.
        if apMacClientCount.count > 1 {
            // Identify the primary router AP: highest client count wins; 6GHz clients are tie-breaker
            let sortedAPs = apMacClientCount.sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                // Prefer the AP that has a 6GHz client (more likely to be the router)
                let a6 = deviceBlocks.filter { ($0["ConnAPMAC"] ?? "").uppercased() == a.key }
                                     .contains { ($0["ConnectionType"] ?? "").contains("6") }
                let b6 = deviceBlocks.filter { ($0["ConnAPMAC"] ?? "").uppercased() == b.key }
                                     .contains { ($0["ConnectionType"] ?? "").contains("6") }
                return a6 && !b6
            }
            let routerAPMac = sortedAPs.first?.key ?? ""

            for (apMAC, clientCount) in apMacClientCount where apMAC != routerAPMac {
                let macSuffix = apMAC.components(separatedBy: ":").suffix(2).joined(separator: ":")
                parsedSats.append(OrbiSatellite(
                    mac:          apMAC,
                    name:         "Satellite (\(macSuffix))",
                    ip:           "",
                    backhaulBand: "",   // not determinable from client-side data
                    clientCount:  clientCount,
                    isOnline:     true
                ))
            }
        }

        let satelliteNodes = parsedSats.map(\.name)

        if totalClients > 0 {
            metrics.append(ConnectorMetric(
                key: "total_clients", label: "Connected Clients",
                value: Double(totalClients), unit: ""))
        }
        if clients24G > 0 {
            metrics.append(ConnectorMetric(
                key: "clients_2g", label: "2.4 GHz Clients",
                value: Double(clients24G), unit: ""))
        }
        if clients5G > 0 {
            metrics.append(ConnectorMetric(
                key: "clients_5g", label: "5 GHz Clients",
                value: Double(clients5G), unit: ""))
        }
        if clients6G > 0 {
            metrics.append(ConnectorMetric(
                key: "clients_6g", label: "6 GHz Clients",
                value: Double(clients6G), unit: ""))
        }
        if !satelliteNodes.isEmpty {
            metrics.append(ConnectorMetric(
                key: "satellite_nodes", label: "Satellite Nodes",
                value: Double(satelliteNodes.count), unit: "online",
                severity: .ok))
        }

        // ── Guest network ─────────────────────────────────────────────────────
        if let guestEnabled = guest?["NewGuestAccessEnabled"] {
            let on = guestEnabled == "1"
            metrics.append(ConnectorMetric(
                key: "guest_enabled", label: "Guest Network",
                value: on ? 1 : 0, unit: on ? "ON" : "OFF",
                severity: on ? .info : .ok))
        }

        // ── Firmware update available ─────────────────────────────────────────
        let newFWVersion  = newFW?["NewFirmwareVersion"] ?? newFW?["NewVersion"] ?? ""
        let curFWVersion  = info?["Firmwareversion"] ?? info?["FirmwareVersion"] ?? ""
        let fwUpdateAvail = !newFWVersion.isEmpty && newFWVersion != curFWVersion && newFWVersion != "N/A"
        if fwUpdateAvail {
            metrics.append(ConnectorMetric(
                key: "fw_update", label: "FW Update",
                value: 1, unit: newFWVersion,
                severity: .info))
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

        // Firmware update available
        if fwUpdateAvail {
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "fw_update_available",
                description: "Firmware update available: \(newFWVersion) (installed: \(curFWVersion.isEmpty ? "unknown" : curFWVersion))",
                severity: .info))
        }

        // ── Summary ──────────────────────────────────────────────────────────

        let model      = info?["ModelName"] ?? "Orbi"
        let wanIP      = metrics.first(where: { $0.key == "wan_ip"      })?.unit ?? "–"
        let todayRX    = metrics.first(where: { $0.key == "today_rx_mb" })
                                .map { String(format: "%.0f", $0.value) } ?? "–"
        let clientStr  = totalClients > 0 ? " · \(totalClients) clients" : ""
        let satStr     = satelliteNodes.isEmpty ? "" : " · \(satelliteNodes.count) sat\(satelliteNodes.count == 1 ? "" : "s")"
        let summary    = "\(model) · WAN \(wanIP) · Today RX \(todayRX) MB\(clientStr)\(satStr)"

        let snapshot = ConnectorSnapshot(
            connectorId: id, connectorName: displayName,
            timestamp: Date(), metrics: metrics, events: events, summary: summary)

        // Build router summary for OrbiIntelligenceView
        var summary2 = OrbiRouterSummary()
        summary2.model         = info?["ModelName"] ?? "Orbi"
        summary2.firmware      = info?["Firmwareversion"] ?? info?["FirmwareVersion"] ?? ""
        summary2.wanIP         = metrics.first(where: { $0.key == "wan_ip" })?.unit ?? ""
        summary2.wanConnected  = metrics.first(where: { $0.key == "wan_status" })?.severity == .ok
        summary2.wanStatus     = metrics.first(where: { $0.key == "wan_status" })?.unit ?? ""
        summary2.cpuPct        = metrics.first(where: { $0.key == "cpu_pct" })?.value
        summary2.memPct        = metrics.first(where: { $0.key == "mem_pct" })?.value
        summary2.totalClients  = totalClients
        summary2.todayRXmb     = metrics.first(where: { $0.key == "today_rx_mb" })?.value
        summary2.todayTXmb     = metrics.first(where: { $0.key == "today_tx_mb" })?.value
        summary2.weekRXmb      = metrics.first(where: { $0.key == "week_rx_mb" })?.value
        summary2.guestEnabled  = metrics.first(where: { $0.key == "guest_enabled" })?.value == 1
        summary2.firmwareUpdate = fwUpdateAvail ? newFWVersion : ""
        lastRouterSummary = summary2
        lastSatellites    = parsedSats

        isConnected  = true
        lastError    = nil
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: - ~/.env reader

    /// Parse KEY=value pairs from ~/.env, ignoring blank lines and comments.
    private static func loadEnv() -> [String: String] {
        let path = ("~/.env" as NSString).expandingTildeInPath
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var env: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eqRange = trimmed.range(of: "=") else { continue }
            let key   = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
            let value = String(trimmed[eqRange.upperBound...])
            env[key] = value
        }
        return env
    }

    private var orbiHost: String {
        let env = Self.loadEnv()
        return env["ORBI_HOST"] ?? (config.host.isEmpty ? "192.168.40.161" : config.host)
    }
    private var orbiUser: String {
        let env = Self.loadEnv()
        return env["ORBI_USER"] ?? (config.username.isEmpty ? "admin" : config.username)
    }
    private var orbiPass: String {
        let env = Self.loadEnv()
        return env["ORBI_PASS"] ?? config.password
    }

    // MARK: - Auth

    /// Ensure we have a valid session cookie. Calls SOAPLogin if needed.
    private func ensureLoggedIn() async throws {
        guard sessionCookie == nil else { return }

        let serviceURN = "urn:NETGEAR-ROUTER:service:DeviceConfig:1"

        let body = soapEnvelope(action: "SOAPLogin", serviceURN: serviceURN,
                                 params: "<Username>\(orbiUser)</Username>\n<Password>\(orbiPass)</Password>")

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
        let port = config.port > 0 ? config.port : 443
        return URL(string: "https://\(orbiHost):\(port)/soap/server_sa/")!
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

    /// Fetch raw SOAP response body as a String (for actions that return nested XML).
    private func fetchRawSOAP(_ action: String, service: String) async throws -> String {
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
            throw ConnectorError.httpError(code)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func optionalRawSOAP(_ action: String, service: String) async -> String? {
        try? await fetchRawSOAP(action, service: service)
    }

    /// Parse <Device> blocks from a GetAttachDevice2 XML response body.
    /// V7 RBRE960 firmware returns structured nested XML, not pipe/at-delimited format.
    private func parseDeviceBlocks(_ xml: String) -> [[String: String]] {
        guard !xml.isEmpty,
              let blockRegex = try? NSRegularExpression(pattern: #"<Device>(.*?)</Device>"#,
                                                         options: .dotMatchesLineSeparators),
              let fieldRegex = try? NSRegularExpression(pattern: #"<([A-Za-z][A-Za-z0-9_]*)>([^<]*)</\1>"#)
        else { return [] }

        var devices: [[String: String]] = []
        let range = NSRange(xml.startIndex..., in: xml)

        for blockMatch in blockRegex.matches(in: xml, range: range) {
            guard let blockRange = Range(blockMatch.range(at: 1), in: xml) else { continue }
            let block = String(xml[blockRange])
            var device: [String: String] = [:]
            let blockNSRange = NSRange(block.startIndex..., in: block)
            for fieldMatch in fieldRegex.matches(in: block, range: blockNSRange) {
                guard let keyRange = Range(fieldMatch.range(at: 1), in: block),
                      let valRange = Range(fieldMatch.range(at: 2), in: block) else { continue }
                device[String(block[keyRange])] =
                    String(block[valRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !device.isEmpty { devices.append(device) }
        }
        return devices
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
