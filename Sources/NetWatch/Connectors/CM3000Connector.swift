/// CM3000Connector.swift — NetWatch connector for Netgear CM3000 cable modem
///
/// The CM3000 sits at 192.168.100.1 on the WAN side of Firewalla. It cannot
/// be reached directly from the LAN, so this connector shells out to a Python
/// script that opens an SSH tunnel through Firewalla and scrapes the modem's
/// built-in web UI.
///
/// Companion script:
///   ~/Documents/Claude/mcp-servers/netwatch-cm3000-snapshot.py
///
/// Credentials (from ~/.env):
///   FIREWALLA_SSH_PASS_UUID   1Password UUID for Firewalla SSH password
///   CM3000_1PASS_ITEM         1Password UUID for modem admin password
///
/// Metrics surfaced:
///   • Downstream channel count + avg/min SNR (dB) + avg receive power (dBmV)
///   • Upstream channel count + avg transmit power (dBmV)
///   • DOCSIS startup status
///
/// Events:
///   • SNR degradation (< 38 dB avg → warning, < 33 dB → critical)
///   • High upstream transmit power (> 46 dBmV indicates poor upstream signal)
///   • T3/T4 timeout errors from the event log
///   • Startup step failures

import Foundation

// MARK: - Connector

final class CM3000Connector: DeviceConnector {

    // MARK: - Identity

    let id          = "cm3000"
    let displayName = "Netgear CM3000"
    let iconName    = "cable.connector.horizontal"

    // MARK: - State

    private(set) var config:       ConnectorConfig
    private(set) var isConnected:  Bool    = false
    private(set) var lastError:    String? = nil
    private(set) var lastSnapshot: ConnectorSnapshot? = nil

    // MARK: - Init

    init(config: ConnectorConfig = ConnectorConfig(id: "cm3000")) {
        self.config = config
    }

    // MARK: - DeviceConnector

    func configure(_ config: ConnectorConfig) {
        self.config = config
    }

    func testConnection() async -> Result<String, Error> {
        do {
            let json    = try await runSnapshot()
            let model   = json["model"]    as? String ?? "CM3000"
            let fw      = json["firmware"] as? String ?? "unknown"
            let dsCh    = json["downstream_count"] as? Int ?? 0
            let snr     = json["avg_snr_db"] as? Double
            let snrStr  = snr.map { String(format: "%.1f dB SNR", $0) } ?? "–"
            return .success("\(model) · FW \(fw) · \(dsCh) DS channels · \(snrStr)")
        } catch {
            return .failure(error)
        }
    }

    func fetchSnapshot() async throws -> ConnectorSnapshot {
        let json = try await runSnapshot()

        // ── Metrics ──────────────────────────────────────────────────────────

        var metrics: [ConnectorMetric] = []

        // Downstream channel count
        if let dsCh = json["downstream_count"] as? Int {
            metrics.append(ConnectorMetric(
                key: "ds_channels", label: "DS Channels",
                value: Double(dsCh), unit: ""))
        }

        // Average downstream SNR
        if let avgSNR = json["avg_snr_db"] as? Double {
            let sev: MetricSeverity = avgSNR >= 38 ? .ok : (avgSNR >= 33 ? .warning : .critical)
            metrics.append(ConnectorMetric(
                key: "avg_snr_db", label: "Avg DS SNR",
                value: avgSNR, unit: "dB", severity: sev))
        }

        // Min downstream SNR (worst channel)
        if let minSNR = json["min_snr_db"] as? Double {
            let sev: MetricSeverity = minSNR >= 38 ? .ok : (minSNR >= 33 ? .warning : .critical)
            metrics.append(ConnectorMetric(
                key: "min_snr_db", label: "Min DS SNR",
                value: minSNR, unit: "dB", severity: sev))
        }

        // Average downstream receive power
        if let dsPwr = json["avg_ds_power_dbmv"] as? Double {
            let sev: MetricSeverity = abs(dsPwr) <= 7 ? .ok : (abs(dsPwr) <= 15 ? .warning : .critical)
            metrics.append(ConnectorMetric(
                key: "avg_ds_power", label: "DS Power",
                value: dsPwr, unit: "dBmV", severity: sev))
        }

        // Upstream channel count + avg transmit power
        if let usCh = json["upstream_count"] as? Int {
            metrics.append(ConnectorMetric(
                key: "us_channels", label: "US Channels",
                value: Double(usCh), unit: ""))
        }
        if let usPwr = json["avg_us_power_dbmv"] as? Double {
            let sev: MetricSeverity = usPwr <= 46 ? .ok : (usPwr <= 51 ? .warning : .critical)
            metrics.append(ConnectorMetric(
                key: "avg_us_power", label: "US Tx Power",
                value: usPwr, unit: "dBmV", severity: sev))
        }

        // DOCSIS startup
        let startupOK = json["startup_ok"] as? Bool ?? true
        metrics.append(ConnectorMetric(
            key: "startup_ok", label: "DOCSIS Init",
            value: startupOK ? 1 : 0,
            unit: startupOK ? "OK" : "FAIL",
            severity: startupOK ? .ok : .critical))

        // ── Events ───────────────────────────────────────────────────────────

        var events: [ConnectorEvent] = []

        // Signal severity events
        let dsSev = json["ds_signal_severity"] as? String ?? "ok"
        let usSev = json["us_signal_severity"] as? String ?? "ok"

        if dsSev == "critical" || dsSev == "warning" {
            let sev: MetricSeverity = dsSev == "critical" ? .critical : .warning
            let snrVal = (json["min_snr_db"] as? Double).map { String(format: "%.1f dB", $0) } ?? "–"
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "signal_degraded",
                description: "Downstream signal degraded — min SNR \(snrVal)",
                severity: sev))
        }

        if usSev == "critical" || usSev == "warning" {
            let sev: MetricSeverity = usSev == "critical" ? .critical : .warning
            let pwrVal = (json["avg_us_power_dbmv"] as? Double).map { String(format: "%.1f dBmV", $0) } ?? "–"
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "upstream_high_power",
                description: "Upstream TX power elevated (\(pwrVal)) — possible signal loss upstream",
                severity: sev))
        }

        if !startupOK {
            events.append(ConnectorEvent(
                timestamp: Date(),
                type: "docsis_init_fail",
                description: "DOCSIS initialization step failed",
                severity: .critical))
        }

        // Error events from modem log (T3/T4 timeouts, uncorrectables)
        if let errorEvents = json["error_events"] as? [[String: Any]], !errorEvents.isEmpty {
            for ev in errorEvents.prefix(5) {
                let text = ev.values.compactMap { $0 as? String }.joined(separator: " ")
                let isCritical = text.lowercased().contains("t4") || text.lowercased().contains("lost sync")
                events.append(ConnectorEvent(
                    timestamp: Date(),
                    type: "modem_error",
                    description: text,
                    severity: isCritical ? .critical : .warning))
            }
        }

        // ── Summary ──────────────────────────────────────────────────────────

        let model  = json["model"]      as? String ?? "CM3000"
        let dsCh   = json["downstream_count"] as? Int ?? 0
        let usCh   = json["upstream_count"]   as? Int ?? 0
        let avgSNR = json["avg_snr_db"]  as? Double
        let snrStr = avgSNR.map { String(format: "avg SNR %.1f dB", $0) } ?? "SNR –"
        let summary = "\(model) · \(dsCh) DS / \(usCh) US channels · \(snrStr)"

        let snapshot = ConnectorSnapshot(
            connectorId: id, connectorName: displayName,
            timestamp: Date(), metrics: metrics, events: events, summary: summary)

        isConnected  = true
        lastError    = nil
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: - Process

    private var snapshotScriptPath: String {
        let custom = config.host
        if !custom.isEmpty && custom.hasSuffix(".py") { return custom }
        return (NSString("~/Documents/Claude/mcp-servers/netwatch-cm3000-snapshot.py")
            as NSString).expandingTildeInPath
    }

    private static let pythonPath = "/opt/homebrew/bin/python3.11"

    private func runSnapshot() async throws -> [String: Any] {
        let scriptPath = snapshotScriptPath
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            isConnected = false
            lastError   = "CM3000 snapshot script not found at \(scriptPath)"
            throw ConnectorError.missingConfig("cm3000 snapshot script")
        }

        let output = try await runProcess(
            executable: Self.pythonPath,
            arguments:  [scriptPath],
            timeoutSec: 45
        )

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            isConnected = false
            lastError   = "Invalid JSON from CM3000 snapshot script"
            throw ConnectorError.parseError("Invalid JSON")
        }

        if let error = json["error"] as? String {
            isConnected = false
            lastError   = error
            throw ConnectorError.parseError(error)
        }

        return json
    }

    // Resume-once gated Process wrapper (same pattern as FirewallaConnector).
    private func runProcess(executable: String, arguments: [String], timeoutSec: Double) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process    = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL  = URL(fileURLWithPath: executable)
            process.arguments      = arguments
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            let lock    = NSLock()
            var resumed = false
            func resumeOnce(_ result: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
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
                process.terminate(); timer.cancel()
                resumeOnce(.failure(ConnectorError.parseError("CM3000 script timed out")))
            }
            timer.resume()

            process.terminationHandler = { _ in
                timer.cancel()
                let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    resumeOnce(.success(out))
                } else {
                    let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    let msg = out.isEmpty ? err : out
                    resumeOnce(.failure(ConnectorError.parseError(
                        msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Script exited \(process.terminationStatus)"
                            : msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    )))
                }
            }

            do { try process.run() } catch {
                timer.cancel()
                resumeOnce(.failure(error))
            }
        }
    }
}
