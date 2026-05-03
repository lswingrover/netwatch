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
///   GetInfo                   — firmware, model, serial, WAN IP, connection type
///   GetSystemInfo             — uptime, CPU load %, memory % (some models)
///   GetTrafficMeterStatistics — per-day/week RX/TX byte totals
///   ETHConfigInfoGet          — per-port link speed/status (some models)
///   GetAttachDevice           — connected client list → count
///   GetNewFirmware            — firmware update availability
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
        // ── Fire all SOAP calls in parallel ───────────────────────────────────
        // optionalSOAP returns nil on unsupported actions (SOAP fault / HTTP error)
        async let infoResult      = optionalSOAP("GetInfo",                   service: "DeviceInfo")
        async let trafficResult   = optionalSOAP("GetTrafficMeterStatistics", service: "TrafficMeter")
        async let sysInfoResult   = optionalSOAP("GetSystemInfo",             service: "DeviceInfo")
        async let ethResult       = optionalSOAP("ETHConfigInfoGet",          service: "DeviceConfig")
        async let attachResult    = optionalSOAP("GetAttachDevice",           service: "AttachDevice")
        async let firmwareResult  = optionalSOAP("GetNewFirmware",            service: "FirmwareCheck")

        let (info, traffic, sysInfo, ethInfo, attachInfo, fwInfo) = await (
            infoResult, trafficResult, sysInfoResult, ethResult, attachResult, firmwareResult
        )

        // ── Metrics ──────────────────────────────────────────────────────────

        var metrics: [ConnectorMetric] = []

        // ── GetInfo: WAN IP, connection type, firmware, uptime (fallback) ─────
        let model    = info?["ModelName"]        ?? "Nighthawk"
        let firmware = info?["Firmwareversion"]  ?? ""
        if let wanIP = info?["ExternalIPAddress"], !wanIP.isEmpty {
            metrics.append(ConnectorMetric(
                key: "wan_ip", label: "WAN IP",
                value: 0, unit: wanIP))
        }
        if let connState = info?["ConnectionType"], !connState.isEmpty {
            metrics.append(ConnectorMetric(
                key: "conn_type", label: "Connection",
                value: 0, unit: connState))
        }
        if !firmware.isEmpty {
            metrics.append(ConnectorMetric(
                key: "firmware", label: "Firmware",
                value: 0, unit: firmware))
        }

        // ── GetSystemInfo: uptime, CPU load, memory ───────────────────────────
        var uptimeH: Double? = nil
        if let sys = sysInfo ?? info {   // GetSystemInfo preferred; fall back to GetInfo
            if let uptime = uptimeSeconds(from: sys["Uptime"] ?? "") {
                uptimeH = uptime / 3600
                metrics.append(ConnectorMetric(
                    key: "uptime_h", label: "Uptime",
                    value: uptime / 3600, unit: "h"))
            }
        }
        if let sys = sysInfo {
            // CPU utilization (0-100 %)
            if let cpuStr = sys["CPUUtilization"] ?? sys["ProcessorLoad"],
               let cpu = Double(cpuStr.trimmingCharacters(in: .init(charactersIn: "% "))) {
                let sev: MetricSeverity = cpu < 70 ? .ok : (cpu < 90 ? .warning : .critical)
                metrics.append(ConnectorMetric(
                    key: "cpu_pct", label: "CPU Load",
                    value: cpu, unit: "%", severity: sev))
            }
            // Memory utilization — prefer MemoryUtilization %; compute from Free/Physical if absent
            if let memPctStr = sys["MemoryUtilization"],
               let memPct = Double(memPctStr.trimmingCharacters(in: .init(charactersIn: "% "))) {
                let sev: MetricSeverity = memPct < 75 ? .ok : (memPct < 90 ? .warning : .critical)
                metrics.append(ConnectorMetric(
                    key: "mem_pct", label: "Memory",
                    value: memPct, unit: "%", severity: sev))
            } else if let totalStr = sys["PhysicalMemory"], let freeStr = sys["FreeMemory"],
                      let total = Double(totalStr), let free = Double(freeStr), total > 0 {
                let usedPct = (1.0 - free / total) * 100.0
                let sev: MetricSeverity = usedPct < 75 ? .ok : (usedPct < 90 ? .warning : .critical)
                metrics.append(ConnectorMetric(
                    key: "mem_pct", label: "Memory",
                    value: usedPct, unit: "%", severity: sev))
                metrics.append(ConnectorMetric(
                    key: "mem_free_mb", label: "Free RAM",
                    value: free, unit: "MB"))
            }
        }

        // ── GetTrafficMeterStatistics: today/week bandwidth ───────────────────
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
            if let weekTxStr = traffic["WeekUpload"], let weekTx = Double(weekTxStr) {
                metrics.append(ConnectorMetric(
                    key: "week_tx_mb", label: "Week TX",
                    value: weekTx, unit: "MB"))
            }
        }

        // ── ETHConfigInfoGet: per-port link speed/status ──────────────────────
        // Netgear returns NewEthernetStatus as pipe+comma delimited:
        // "1|1000M|Full|0|100M|Half" → (portEnabled|speed|duplex) per port
        var ethPortMetrics = 0
        if let eth = ethInfo,
           let ethStatus = eth["NewEthernetStatus"] ?? eth["EthernetStatus"] {
            let ports = parseEthPorts(ethStatus)
            for (idx, port) in ports.enumerated() {
                let portNum = idx + 1
                let linked  = port.linked
                let speed   = port.speed
                metrics.append(ConnectorMetric(
                    key:   "eth_port_\(portNum)",
                    label: "ETH Port \(portNum)",
                    value: linked ? 1 : 0,
                    unit:  linked ? speed : "down",
                    severity: linked ? .ok : .info))
                ethPortMetrics += 1
            }
        }

        // ── GetAttachDevice: connected client count ───────────────────────────
        var clientCount: Int? = nil
        if let attach = attachInfo,
           let deviceList = attach["NewAttachDevice"] ?? attach["AttachDevice"] {
            // Each device is a pipe-delimited line: name|ip|mac|conn|signal
            let entries = deviceList
                .components(separatedBy: "@")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !entries.isEmpty {
                clientCount = entries.count
                metrics.append(ConnectorMetric(
                    key: "client_count", label: "Connected Clients",
                    value: Double(entries.count), unit: ""))
            }
        }

        // ── GetNewFirmware: update available? ─────────────────────────────────
        var firmwareUpdateAvailable = false
        if let fw = fwInfo {
            let newVer = fw["NewFirmwareVersion"] ?? fw["FirmwareVersion"] ?? ""
            firmwareUpdateAvailable = !newVer.isEmpty && newVer != "N/A" && newVer != firmware
            if firmwareUpdateAvailable {
                metrics.append(ConnectorMetric(
                    key: "firmware_update", label: "Firmware Update",
                    value: 1, unit: newVer,
                    severity: .warning))
            }
        }

        // ── Events ───────────────────────────────────────────────────────────

        var events: [ConnectorEvent] = []

        // Recent reboot
        if let uh = uptimeH, uh < (5.0 / 60.0) {
            events.append(ConnectorEvent(
                timestamp: Date(), type: "reboot",
                description: "Router recently rebooted (uptime < 5 minutes)",
                severity: .warning))
        }

        // High CPU
        if let cpuMetric = metrics.first(where: { $0.key == "cpu_pct" }),
           cpuMetric.severity == .warning || cpuMetric.severity == .critical {
            events.append(ConnectorEvent(
                timestamp: Date(), type: "high_cpu",
                description: String(format: "CPU load elevated: %.0f%%", cpuMetric.value),
                severity: cpuMetric.severity))
        }

        // High memory
        if let memMetric = metrics.first(where: { $0.key == "mem_pct" }),
           memMetric.severity == .warning || memMetric.severity == .critical {
            events.append(ConnectorEvent(
                timestamp: Date(), type: "high_memory",
                description: String(format: "Memory usage elevated: %.0f%%", memMetric.value),
                severity: memMetric.severity))
        }

        // Firmware update available
        if firmwareUpdateAvailable,
           let newVerMetric = metrics.first(where: { $0.key == "firmware_update" }) {
            events.append(ConnectorEvent(
                timestamp: Date(), type: "firmware_update",
                description: "Firmware update available: \(newVerMetric.unit)",
                severity: .warning))
        }

        // ── Summary ──────────────────────────────────────────────────────────

        let wanIPStr    = info?["ExternalIPAddress"] ?? "–"
        let todayRX     = metrics.first { $0.key == "today_rx_mb" }.map { String(format: "%.0f MB", $0.value) } ?? "–"
        let clientStr   = clientCount.map { " · \($0) clients" } ?? ""
        let fwStr       = firmware.isEmpty ? "" : " · FW \(firmware)"
        let summary     = "\(model)\(fwStr) · WAN \(wanIPStr) · Today RX \(todayRX)\(clientStr)"

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

    /// Parsed representation of a single Ethernet port entry.
    private struct EthPort {
        let linked: Bool
        let speed:  String   // e.g. "1000M", "100M"
        let duplex: String   // "Full" or "Half"
    }

    /// Parses Netgear ETH port status strings.
    ///
    /// Two common formats observed across Nighthawk firmware versions:
    ///
    ///   Format A — pipe-separated triplets, one port per '@' group:
    ///     "1|1000M|Full@0|100M|Half@1|100M|Full"
    ///     Fields: linked(0/1) | speed | duplex
    ///
    ///   Format B — space-separated link indicators per port:
    ///     "Up|1000M Down|0M Up|100M"
    ///
    /// Returns an array of EthPort in port-index order.
    private func parseEthPorts(_ raw: String) -> [EthPort] {
        // Try Format A (@ delimited groups of pipe-separated values)
        let atGroups = raw.components(separatedBy: "@").filter { !$0.isEmpty }
        if atGroups.count > 1 {
            return atGroups.compactMap { group in
                let parts = group.components(separatedBy: "|")
                guard parts.count >= 2 else { return nil }
                let linked = parts[0].trimmingCharacters(in: .whitespaces) == "1"
                let speed  = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "?"
                let duplex = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
                return EthPort(linked: linked, speed: speed, duplex: duplex)
            }
        }

        // Try Format B — "Up|1000M" tokens
        let tokens = raw.components(separatedBy: " ").filter { !$0.isEmpty }
        var ports: [EthPort] = []
        for token in tokens {
            let parts = token.components(separatedBy: "|")
            if parts.count >= 2 {
                let state = parts[0].lowercased()
                let speed = parts[1]
                let linked = state == "up" || state == "1"
                ports.append(EthPort(linked: linked, speed: speed, duplex: ""))
            }
        }
        if !ports.isEmpty { return ports }

        // Fallback: single value like "1000M" or "Down"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let linked  = !trimmed.lowercased().contains("down") && !trimmed.isEmpty
        return [EthPort(linked: linked, speed: trimmed, duplex: "")]
    }
}
