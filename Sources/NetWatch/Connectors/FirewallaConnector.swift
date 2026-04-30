/// FirewallaConnector.swift — NetWatch connector for Firewalla Gold
///
/// Uses SSH→Redis to pull data directly from the Firewalla box, the same
/// approach as the network-mcp server in ~/Documents/Claude/mcp-servers/.
///
/// All auth is handled by a companion Python script:
///   ~/Documents/Claude/mcp-servers/netwatch-firewalla-snapshot.py
///
/// The script reads credentials from ~/.env:
///   FIREWALLA_IP              LAN IP (default 192.168.40.1)
///   FIREWALLA_SSH_USER        SSH user (default pi)
///   FIREWALLA_SSH_PASS_UUID   1Password item UUID for SSH password
///
/// No Box API Token or REST API needed — the Firewalla Gold REST API on port
/// 8833 is unreliable (returns HTTP 400); SSH→Redis is the proven approach.
///
/// The connector shells out to python3.11 with the snapshot script and parses
/// the JSON result. Process execution is async-bridged via a continuation.
///
/// Tested on: Firewalla Gold v1.982 Beta

import Foundation

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

        // Uptime
        if let uptimeS = json["uptime_seconds"] as? Double, uptimeS > 0 {
            metrics.append(ConnectorMetric(
                key: "uptime_h", label: "Uptime",
                value: uptimeS / 3600, unit: "h"))
        }

        // ── Events ───────────────────────────────────────────────────────────

        var events: [ConnectorEvent] = []

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

        // ── Summary ──────────────────────────────────────────────────────────

        let pubIP      = json["public_ip"]    as? String ?? "–"
        let alarmCount = json["alarm_count"]  as? Int    ?? 0
        let devCount   = json["total_devices"] as? Int   ?? 0
        let summary    = "Firewalla Gold · Public \(pubIP) · \(devCount) devices · \(alarmCount) alarm(s)"

        let snapshot = ConnectorSnapshot(
            connectorId: id, connectorName: displayName,
            timestamp: Date(), metrics: metrics, events: events, summary: summary)

        isConnected  = true
        lastError    = nil
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: - Process

    /// Path to the companion Python snapshot script.
    private var snapshotScriptPath: String {
        let custom = config.host   // reuse host field as optional script override
        if !custom.isEmpty && custom.hasSuffix(".py") { return custom }
        let base = NSString("~/Documents/Claude/mcp-servers/netwatch-firewalla-snapshot.py")
        return base.expandingTildeInPath
    }

    private static let pythonPath = "/opt/homebrew/bin/python3.11"

    /// Run the snapshot script and return the decoded JSON dictionary.
    private func runSnapshot() async throws -> [String: Any] {
        let scriptPath = snapshotScriptPath

        // Verify script exists
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            isConnected = false
            lastError   = "Snapshot script not found at \(scriptPath)"
            throw ConnectorError.missingConfig("snapshot script")
        }

        let output = try await runProcess(
            executable: Self.pythonPath,
            arguments:  [scriptPath],
            timeoutSec: 45      // SSH + Redis queries can take a few seconds
        )

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            isConnected = false
            lastError   = "Invalid JSON from snapshot script"
            throw ConnectorError.parseError("Invalid JSON")
        }

        if let error = json["error"] as? String {
            isConnected = false
            lastError   = error
            throw ConnectorError.parseError(error)
        }

        return json
    }

    /// Async wrapper around Process + Pipe.
    ///
    /// Uses a `resumeOnce` gate (NSLock + Bool flag) to prevent the double-resume
    /// crash that occurs when the timeout fires first, calls process.terminate(),
    /// and then the terminationHandler also fires — both trying to resume the same
    /// CheckedContinuation. Only the first resume wins; subsequent ones are no-ops.
    private func runProcess(executable: String, arguments: [String], timeoutSec: Double) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL  = URL(fileURLWithPath: executable)
            process.arguments      = arguments
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            // ── Once-only resume gate ──────────────────────────────────────
            // Both the timeout handler and the terminationHandler can fire for
            // the same process run (timeout → terminate() → terminationHandler).
            // Gate ensures continuation.resume is called exactly once.
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

            // ── Timeout watchdog ──────────────────────────────────────────
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeoutSec)
            timer.setEventHandler {
                process.terminate()
                timer.cancel()
                resumeOnce(.failure(ConnectorError.parseError("Snapshot script timed out after \(Int(timeoutSec))s")))
            }
            timer.resume()

            process.terminationHandler = { _ in
                timer.cancel()
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) ?? ""
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
