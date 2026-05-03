/// FirewallaConnector.swift — NetWatch connector for Firewalla Gold
///
/// Uses SSH→Redis to pull data directly from the Firewalla box, the same
/// approach as the network-mcp server in ~/Documents/Claude/mcp-servers/.
///
/// All auth is handled by a companion Python script:
///   ~/Documents/Claude/mcp-servers/netwatch-firewalla-snapshot.py
///
/// Device actions (pause/resume/block domain) use a second script:
///   ~/Documents/Claude/mcp-servers/netwatch-firewalla-actions.py
///
/// Both scripts read credentials from ~/.env:
///   FIREWALLA_IP              LAN IP (default 192.168.40.1)
///   FIREWALLA_SSH_USER        SSH user (default pi)
///   FIREWALLA_SSH_PASS        SSH password (plaintext — preferred)
///   FIREWALLA_SSH_PASS_UUID   1Password item UUID (fallback if FIREWALLA_SSH_PASS unset)
///
/// No Box API Token or REST API needed — the Firewalla Gold REST API on port
/// 8833 is unreliable (returns HTTP 400); SSH→Redis is the proven approach.
///
/// Tested on: Firewalla Gold v1.982 Beta

import Foundation

// MARK: - Firewalla-specific data models

/// A device seen on the network by Firewalla.
struct FirewallaDevice: Identifiable, Equatable {
    var id: String { mac }

    let mac:        String
    let name:       String
    let ip:         String
    let upload:     Int       // bytes total
    let download:   Int       // bytes total
    let vendor:     String
    let isPaused:   Bool
    let isOnline:   Bool      // last-seen < 5 min
    let lastActive: Date?
    let firstSeen:  Date?

    var totalBytes: Int { upload + download }

    /// Formatted bandwidth string (e.g. "1.2 GB" / "450 MB")
    var totalBandwidthFormatted: String {
        FirewallaDevice.formatBytes(totalBytes)
    }

    static func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1_024
        let mb = kb / 1_024
        let gb = mb / 1_024
        if gb >= 1    { return String(format: "%.1f GB", gb) }
        if mb >= 1    { return String(format: "%.0f MB", mb) }
        if kb >= 1    { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }
}

/// A recent network flow recorded by Firewalla.
struct FirewallaFlow: Identifiable {
    var id: String { "\(timestamp.timeIntervalSince1970)-\(mac)-\(domain)" }

    let timestamp: Date
    let mac:       String
    let device:    String
    let domain:    String
    let ip:        String
    let bytes:     Int
    let protocol_: String
    let category:  String
    let isBlocked: Bool
}

/// A DNS domain with aggregated hit count.
struct FirewallaDomain: Identifiable {
    var id: String { domain }
    let domain: String
    let count:  Int
}

/// Actions that can be sent to Firewalla via netwatch-firewalla-actions.py.
enum FirewallaAction {
    case pause(mac: String)
    case resume(mac: String)
    case blockDomain(mac: String, domain: String)
    case unblockDomain(mac: String, domain: String)

    var cliArgs: [String] {
        switch self {
        case .pause(let mac):
            return ["--action", "pause", "--mac", mac]
        case .resume(let mac):
            return ["--action", "resume", "--mac", mac]
        case .blockDomain(let mac, let domain):
            return ["--action", "block_domain", "--mac", mac, "--domain", domain]
        case .unblockDomain(let mac, let domain):
            return ["--action", "unblock_domain", "--mac", mac, "--domain", domain]
        }
    }
}

// MARK: - Connector

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

    // MARK: - Intelligence data (populated on each fetchSnapshot)

    /// Full device list sorted by total bandwidth (descending).
    private(set) var lastDevices: [FirewallaDevice] = []

    /// Recent network flows (last 30 min, up to 100).
    private(set) var lastFlows: [FirewallaFlow] = []

    /// Top DNS domains (last 24h, up to 30).
    private(set) var lastDomains: [FirewallaDomain] = []

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
            let json = try await runSnapshot()
            if let wans = json["wan_interfaces"] as? [[String: Any]] {
                let active = wans.filter { ($0["active"] as? Bool) == true }
                let ip     = (active.first ?? wans.first)?["ip"] as? String ?? "–"
                let count  = json["total_devices"] as? Int ?? 0
                return .success("Firewalla Gold · WAN \(ip) · \(count) devices")
            }
            return .success("Firewalla Gold · connected")
        } catch {
            return .failure(error)
        }
    }

    func fetchSnapshot() async throws -> ConnectorSnapshot {
        let json = try await runSnapshot()

        // Parse intelligence data — stored for use by FirewallaIntelligenceView
        parseIntelligenceData(json)

        // ── Metrics ──────────────────────────────────────────────────────────

        var metrics: [ConnectorMetric] = []

        // WAN active interface
        if let wans = json["wan_interfaces"] as? [[String: Any]] {
            for wan in wans {
                let desc   = wan["desc"]   as? String ?? wan["name"] as? String ?? "WAN"
                let ip     = wan["ip"]     as? String ?? ""
                let active = wan["active"] as? Bool   ?? false
                let ready  = wan["ready"]  as? Bool   ?? false
                let sev: MetricSeverity = active ? .ok : (ready ? .warning : .critical)
                metrics.append(ConnectorMetric(
                    key: "wan_\(wan["name"] as? String ?? "if")",
                    label: "\(desc) WAN",
                    value: 0, unit: ip.isEmpty ? (active ? "up" : "down") : ip,
                    severity: sev))
            }
        }

        // Public IP
        if let pubIP = json["public_ip"] as? String, !pubIP.isEmpty {
            metrics.append(ConnectorMetric(
                key: "public_ip", label: "Public IP",
                value: 0, unit: pubIP))
        }

        // Alarm count
        if let alarmCount = json["alarm_count"] as? Int {
            metrics.append(ConnectorMetric(
                key: "active_alarms", label: "Active Alarms",
                value: Double(alarmCount), unit: "",
                severity: alarmCount > 0 ? .warning : .ok))
        }

        // Devices
        if let total = json["total_devices"] as? Int, total >= 0 {
            metrics.append(ConnectorMetric(
                key: "total_devices", label: "Total Devices",
                value: Double(total), unit: ""))
        }
        if let active = json["active_devices_2h"] as? Int {
            metrics.append(ConnectorMetric(
                key: "active_devices", label: "Active (2h)",
                value: Double(active), unit: ""))
        }

        // Online right now (from full device list)
        let onlineCount = lastDevices.filter { $0.isOnline }.count
        if !lastDevices.isEmpty {
            metrics.append(ConnectorMetric(
                key: "online_devices", label: "Online Now",
                value: Double(onlineCount), unit: ""))
        }

        // Uptime
        if let uptimeS = json["uptime_seconds"] as? Double, uptimeS > 0 {
            metrics.append(ConnectorMetric(
                key: "uptime_h", label: "Uptime",
                value: uptimeS / 3600, unit: "h"))
        }

        // ── Top bandwidth consumer (headline metric) ──────────────────────────
        if let topBW = (json["top_bandwidth"] as? [[String: Any]])?.first,
           let totalBytes = topBW["total"] as? Int, totalBytes > 0 {
            let name   = topBW["name"] as? String ?? topBW["mac"] as? String ?? "Unknown"
            let totalMB = Double(totalBytes) / 1_048_576
            metrics.append(ConnectorMetric(
                key: "top_bw_device", label: "Top Consumer",
                value: totalMB, unit: "MB",
                severity: totalMB > 10_000 ? .warning : .ok))
            metrics.append(ConnectorMetric(
                key: "top_bw_name", label: "Top Consumer Name",
                value: 0, unit: name))
        }

        // Blocking category totals
        if let cats = json["block_categories"] as? [[String: Any]], !cats.isEmpty {
            let topCat  = cats.first
            let catName = topCat?["category"] as? String ?? "unknown"
            let catHits = topCat?["blocked_count"] as? Int ?? 0
            let totalBlocked = cats.reduce(0) { $0 + (($1["blocked_count"] as? Int) ?? 0) }
            metrics.append(ConnectorMetric(
                key: "total_blocked", label: "Blocked Requests",
                value: Double(totalBlocked), unit: "",
                severity: totalBlocked > 1000 ? .info : .ok))
            if catHits > 0 {
                metrics.append(ConnectorMetric(
                    key: "top_block_category", label: "Top Block Category",
                    value: Double(catHits), unit: catName))
            }
        }

        // VPN active tunnel count
        if let vpn = json["vpn_status"] as? [String: Any] {
            let enabled = vpn["enabled"] as? Bool ?? false
            if enabled {
                let tunnelCount = (vpn["active_tunnels"] as? [[String: Any]])?.count ?? 1
                metrics.append(ConnectorMetric(
                    key: "vpn_tunnels", label: "VPN Tunnels",
                    value: Double(tunnelCount), unit: "active",
                    severity: .ok))
            }
        }

        // Top domains count
        if !lastDomains.isEmpty {
            metrics.append(ConnectorMetric(
                key: "unique_domains", label: "Top Domain",
                value: 0, unit: lastDomains.first?.domain ?? ""))
        }

        // Paused devices count
        let pausedCount = lastDevices.filter { $0.isPaused }.count
        if pausedCount > 0 {
            metrics.append(ConnectorMetric(
                key: "paused_devices", label: "Paused",
                value: Double(pausedCount), unit: "devices",
                severity: .info))
        }

        // ── Events ───────────────────────────────────────────────────────────

        var events: [ConnectorEvent] = []

        // Alarms
        if let alarms = json["recent_alarms"] as? [[String: Any]] {
            for alarm in alarms.prefix(10) {
                let ts: Date
                if let tsStr = alarm["timestamp"] as? String,
                   let tsVal = Double(tsStr) {
                    ts = Date(timeIntervalSince1970: tsVal)
                } else {
                    ts = Date()
                }
                let atype   = alarm["type"]    as? String ?? "ALARM"
                let device  = alarm["device"]  as? String ?? "?"
                let message = alarm["message"] as? String ?? atype
                let sev: MetricSeverity = alarm["severity"] as? String == "high" ? .critical : .warning
                let description = message.isEmpty ? "\(atype) — \(device)" : "\(device): \(message)"
                events.append(ConnectorEvent(
                    timestamp: ts,
                    type: "alarm",
                    description: description,
                    severity: sev))
            }
        }

        // New devices in last 24h
        if let newDevs = json["new_devices_24h"] as? [[String: Any]], !newDevs.isEmpty {
            for dev in newDevs.prefix(5) {
                let name = dev["name"] as? String ?? dev["mac"] as? String ?? "Unknown"
                let ip   = dev["ip"]   as? String ?? ""
                let ipStr = ip.isEmpty ? "" : " (\(ip))"
                events.append(ConnectorEvent(
                    timestamp: Date(),
                    type: "new_device",
                    description: "New device joined network: \(name)\(ipStr)",
                    severity: .info))
            }
        }

        // Rebooted recently?
        if let uptimeS = json["uptime_seconds"] as? Double, uptimeS > 0, uptimeS < 300 {
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "reboot",
                description: "Firewalla recently rebooted (uptime < 5 min)",
                severity: .warning))
        }

        // WAN down?
        let anyActiveWAN = (json["wan_interfaces"] as? [[String: Any]])?.contains {
            ($0["active"] as? Bool) == true
        } ?? true
        if !anyActiveWAN, !(json["wan_interfaces"] as? [[String: Any]] ?? []).isEmpty {
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "wan_down",
                description: "No active WAN interface on Firewalla",
                severity: .critical))
        }

        // Top blocked country (geo intelligence event)
        if let topCountry = (json["blocked_countries"] as? [[String: Any]])?.first,
           let count = topCountry["blocked_count"] as? Int, count > 50,
           let country = topCountry["country"] as? String {
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "geo_block_activity",
                description: "Top blocked country: \(country) (\(count) blocked connections)",
                severity: .info))
        }

        // Recent blocked flows
        let blockedFlows = lastFlows.filter { $0.isBlocked }.prefix(3)
        for flow in blockedFlows {
            events.append(ConnectorEvent(
                timestamp: flow.timestamp,
                type: "blocked_flow",
                description: "Blocked: \(flow.domain.isEmpty ? flow.ip : flow.domain) ← \(flow.device)",
                severity: .warning))
        }

        // ── Summary ──────────────────────────────────────────────────────────

        let pubIP      = json["public_ip"]    as? String ?? "–"
        let alarmCount = json["alarm_count"]  as? Int    ?? 0
        let devCount   = json["total_devices"] as? Int   ?? 0
        let newDevCount = (json["new_devices_24h"] as? [[String: Any]])?.count ?? 0
        let newDevStr  = newDevCount > 0 ? " · \(newDevCount) new" : ""
        let pausedStr  = pausedCount > 0 ? " · \(pausedCount) paused" : ""
        let summary    = "Firewalla · \(pubIP) · \(devCount) devices\(newDevStr)\(pausedStr) · \(alarmCount) alarm(s)"

        let snapshot = ConnectorSnapshot(
            connectorId: id, connectorName: displayName,
            timestamp: Date(), metrics: metrics, events: events, summary: summary)

        isConnected  = true
        lastError    = nil
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: - Intelligence data parser

    private func parseIntelligenceData(_ json: [String: Any]) {
        // All devices
        if let rawDevices = json["all_devices"] as? [[String: Any]] {
            lastDevices = rawDevices.compactMap { d -> FirewallaDevice? in
                guard let mac = d["mac"] as? String else { return nil }
                let lastTs = (d["last_active"] as? Double).map { Date(timeIntervalSince1970: $0) }
                let firstTs = (d["first_seen"] as? Double).map { Date(timeIntervalSince1970: $0) }
                return FirewallaDevice(
                    mac:        mac,
                    name:       d["name"]     as? String ?? mac,
                    ip:         d["ip"]       as? String ?? "",
                    upload:     d["upload"]   as? Int    ?? 0,
                    download:   d["download"] as? Int    ?? 0,
                    vendor:     d["vendor"]   as? String ?? "",
                    isPaused:   d["paused"]   as? Bool   ?? false,
                    isOnline:   d["online"]   as? Bool   ?? false,
                    lastActive: lastTs,
                    firstSeen:  firstTs
                )
            }
        }

        // Recent flows
        if let rawFlows = json["recent_flows"] as? [[String: Any]] {
            lastFlows = rawFlows.compactMap { f -> FirewallaFlow? in
                let ts = (f["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
                return FirewallaFlow(
                    timestamp: ts,
                    mac:       f["mac"]      as? String ?? "",
                    device:    f["device"]   as? String ?? "Unknown",
                    domain:    f["domain"]   as? String ?? "",
                    ip:        f["ip"]       as? String ?? "",
                    bytes:     f["bytes"]    as? Int    ?? 0,
                    protocol_: f["protocol"] as? String ?? "",
                    category:  f["category"] as? String ?? "",
                    isBlocked: f["blocked"]  as? Bool   ?? false
                )
            }
        }

        // Top domains
        if let rawDomains = json["top_domains"] as? [[String: Any]] {
            lastDomains = rawDomains.compactMap { d -> FirewallaDomain? in
                guard let domain = d["domain"] as? String,
                      let count  = d["count"]  as? Int else { return nil }
                return FirewallaDomain(domain: domain, count: count)
            }
        }
    }

    // MARK: - Device actions

    /// Execute a control action on the Firewalla (pause/resume device, block/unblock domain).
    /// Returns a descriptive result string on success, or throws on failure.
    func performAction(_ action: FirewallaAction) async throws -> String {
        let scriptPath = actionsScriptPath
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw ConnectorError.missingConfig("actions script at \(scriptPath)")
        }

        let output = try await runProcess(
            executable: Self.pythonPath,
            arguments: [scriptPath] + action.cliArgs,
            timeoutSec: 30
        )

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.parseError("Invalid JSON from actions script")
        }

        if let success = json["success"] as? Bool, success {
            return json["message"] as? String ?? "Action completed"
        } else {
            let err = json["error"] as? String ?? "Unknown error"
            throw ConnectorError.parseError(err)
        }
    }

    // MARK: - Process

    /// Path to the snapshot companion Python script.
    private var snapshotScriptPath: String {
        let custom = config.host
        if !custom.isEmpty && custom.hasSuffix(".py") { return custom }
        let base = NSString("~/Documents/Claude/mcp-servers/netwatch-firewalla-snapshot.py")
        return base.expandingTildeInPath
    }

    /// Path to the actions companion Python script.
    private var actionsScriptPath: String {
        let base = NSString("~/Documents/Claude/mcp-servers/netwatch-firewalla-actions.py")
        return base.expandingTildeInPath
    }

    private static let pythonPath = "/opt/homebrew/bin/python3.11"

    /// Run the snapshot script and return the decoded JSON dictionary.
    private func runSnapshot() async throws -> [String: Any] {
        let scriptPath = snapshotScriptPath

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            isConnected = false
            lastError   = "Snapshot script not found at \(scriptPath)"
            throw ConnectorError.missingConfig("snapshot script")
        }

        let output: String
        do {
            output = try await runProcess(
                executable: Self.pythonPath,
                arguments:  [scriptPath],
                timeoutSec: 45
            )
        } catch {
            isConnected = false
            // Provide a concise error — strip leading "Parse error: " prefix if present
            let msg = (error as? ConnectorError)?.errorDescription ?? error.localizedDescription
            lastError = msg
            throw error
        }

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            isConnected = false
            lastError   = "Invalid JSON from snapshot script (output length: \(output.count))"
            throw ConnectorError.parseError("Invalid JSON")
        }

        if let error = json["error"] as? String {
            isConnected = false
            lastError   = error
            throw ConnectorError.parseError(error)
        }

        return json
    }

    /// Async wrapper around Process + temp-file stdout capture.
    ///
    /// Writes stdout to a temp file instead of a Pipe to avoid the 64 KB pipe-buffer
    /// deadlock that occurs when the script emits large JSON (e.g. 133 KB). Stderr is
    /// still read via Pipe (it's always small).
    ///
    /// Uses a `resumeOnce` gate (NSLock + Bool flag) to prevent the double-resume
    /// crash that occurs when the timeout fires first and then the terminationHandler
    /// also fires.
    private func runProcess(executable: String, arguments: [String], timeoutSec: Double) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // ── Stdout → temp file (avoids pipe-buffer deadlock on large output) ──
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("netwatch-fw-\(UUID().uuidString).json")
            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
            guard let stdoutHandle = try? FileHandle(forWritingTo: tmpURL) else {
                continuation.resume(throwing: ConnectorError.parseError("Cannot create temp file"))
                return
            }

            let process   = Process()
            let stderrPipe = Pipe()

            process.executableURL  = URL(fileURLWithPath: executable)
            process.arguments      = arguments
            process.standardOutput = stdoutHandle
            process.standardError  = stderrPipe

            // Inherit environment; ensure HOME is set so ~/.env and ~/.ssh resolve correctly.
            var env = ProcessInfo.processInfo.environment
            if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
            process.environment = env

            let lock    = NSLock()
            var resumed = false

            func resumeOnce(_ result: Result<String, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let v): continuation.resume(returning: v)
                case .failure(let e): continuation.resume(throwing: e)
                }
            }

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeoutSec)
            timer.setEventHandler {
                process.terminate()
                timer.cancel()
                resumeOnce(.failure(ConnectorError.parseError("Script timed out after \(Int(timeoutSec))s")))
            }
            timer.resume()

            process.terminationHandler = { _ in
                timer.cancel()
                stdoutHandle.closeFile()
                let stdout = (try? String(contentsOf: tmpURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: tmpURL)
                if process.terminationStatus == 0 {
                    resumeOnce(.success(stdout))
                } else {
                    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                       encoding: .utf8) ?? ""
                    let msg = stdout.isEmpty ? stderr : stdout
                    resumeOnce(.failure(ConnectorError.parseError(
                        msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Script exited \(process.terminationStatus)"
                            : msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    )))
                }
            }

            do {
                try process.run()
            } catch {
                stdoutHandle.closeFile()
                try? FileManager.default.removeItem(at: tmpURL)
                timer.cancel()
                resumeOnce(.failure(error))
            }
        }
    }
}

// MARK: - Errors (shared across all connectors)

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
