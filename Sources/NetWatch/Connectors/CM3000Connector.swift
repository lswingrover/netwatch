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
///   FIREWALLA_SSH_PASS        Firewalla SSH password (plaintext — preferred)
///   FIREWALLA_SSH_PASS_UUID   1Password UUID for Firewalla SSH password (fallback)
///   CM3000_ADMIN_PASS         CM3000 admin password (plaintext — preferred)
///   CM3000_1PASS_ITEM         1Password UUID for modem admin password (fallback)
///
/// Metrics surfaced:
///   • Downstream SC-QAM channel count + per-channel SNR/power/uncorrectables
///   • Downstream OFDM channel count + per-channel SNR/power/codewords
///   • Upstream SC-QAM channel count + per-channel transmit power
///   • Total uncorrectable codewords (key early-warning signal quality metric)
///   • Total correctable codewords
///   • Avg/min/max downstream SNR; avg downstream power; avg upstream power
///   • DOCSIS startup status; firmware version
///
/// Events:
///   • SNR degradation (avg < 38 dB → warning, < 33 dB → critical)
///   • High upstream transmit power (> 46 dBmV indicates poor upstream signal)
///   • Any nonzero uncorrectable codewords → warning
///   • Diagnostic messages from modem (partial service, out-of-range power/SNR)
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

        // ── Downstream channel counts (SC-QAM + OFDM separately) ─────────────
        let dsTotal   = json["downstream_count"]        as? Int ?? 0
        let dsScQam   = json["downstream_sc_qam_count"] as? Int ?? dsTotal
        let dsOfdm    = json["downstream_ofdm_count"]   as? Int ?? 0
        let usTotal   = json["upstream_count"]          as? Int ?? 0

        metrics.append(ConnectorMetric(
            key: "ds_channels", label: "DS Channels",
            value: Double(dsTotal), unit: ""))
        if dsOfdm > 0 {
            metrics.append(ConnectorMetric(
                key: "ds_sc_qam", label: "DS SC-QAM",
                value: Double(dsScQam), unit: ""))
            metrics.append(ConnectorMetric(
                key: "ds_ofdm", label: "DS OFDM",
                value: Double(dsOfdm), unit: ""))
        }
        metrics.append(ConnectorMetric(
            key: "us_channels", label: "US Channels",
            value: Double(usTotal), unit: ""))

        // ── Downstream SNR ────────────────────────────────────────────────────
        // DOCSIS 3.0/3.1 spec minimum SNR: 30 dB (256-QAM). Recommended headroom: ≥33 dB.
        // The modem's internal warning threshold (~38 dB) is more conservative than the spec
        // and should NOT drive metric severity in NetWatch. We use spec-based thresholds here.
        if let avgSNR = json["avg_snr_db"] as? Double {
            let sev: MetricSeverity = avgSNR >= 33 ? .ok : (avgSNR >= 30 ? .warning : .critical)
            metrics.append(ConnectorMetric(
                key: "avg_snr_db", label: "Avg DS SNR",
                value: avgSNR, unit: "dB", severity: sev))
        }
        if let minSNR = json["min_snr_db"] as? Double {
            let sev: MetricSeverity = minSNR >= 33 ? .ok : (minSNR >= 30 ? .warning : .critical)
            metrics.append(ConnectorMetric(
                key: "min_snr_db", label: "Min DS SNR",
                value: minSNR, unit: "dB", severity: sev))
        }
        if let maxSNR = json["max_snr_db"] as? Double {
            metrics.append(ConnectorMetric(
                key: "max_snr_db", label: "Max DS SNR",
                value: maxSNR, unit: "dB"))
        }

        // ── Downstream receive power ──────────────────────────────────────────
        // DOCSIS 3.0 spec: −15 to +15 dBmV. Sweet spot: ±7 dBmV. NetWatch uses ±10 as
        // .ok (comfortable headroom) so that readings near 7.x don't falsely trigger .warning.
        if let dsPwr = json["avg_ds_power_dbmv"] as? Double {
            let sev: MetricSeverity = abs(dsPwr) <= 10 ? .ok : (abs(dsPwr) <= 15 ? .warning : .critical)
            metrics.append(ConnectorMetric(
                key: "avg_ds_power", label: "DS Rx Power",
                value: dsPwr, unit: "dBmV", severity: sev))
        }

        // ── Upstream transmit power ───────────────────────────────────────────
        if let usPwr = json["avg_us_power_dbmv"] as? Double {
            let sev: MetricSeverity = usPwr <= 46 ? .ok : (usPwr <= 51 ? .warning : .critical)
            metrics.append(ConnectorMetric(
                key: "avg_us_power", label: "US Tx Power",
                value: usPwr, unit: "dBmV", severity: sev))
        }

        // ── Codeword health (KEY early-warning metric) ────────────────────────
        // Uncorrectable codeword counts are CUMULATIVE since last modem reboot — a large
        // absolute count (e.g. 17,000) does not mean things are bad right now; it means
        // impairment has occurred at some point since boot. NetWatch reports this as .info
        // so it is visible without driving false .warning status. Rate-based assessment
        // requires per-poll delta tracking (tracked in CM3000IntelligenceView).
        let totalUncorr = json["total_uncorr_codewords"] as? Int ?? 0
        let totalCorr   = json["total_corr_codewords"]   as? Int ?? 0
        let uncorrSev: MetricSeverity = totalUncorr == 0 ? .ok : .info
        metrics.append(ConnectorMetric(
            key: "total_uncorr_codewords", label: "Uncorr Codewords",
            value: Double(totalUncorr), unit: "",
            severity: uncorrSev))
        if totalCorr > 0 {
            metrics.append(ConnectorMetric(
                key: "total_corr_codewords", label: "Corr Codewords",
                value: Double(totalCorr), unit: ""))
        }

        // ── DOCSIS startup ────────────────────────────────────────────────────
        let startupOK = json["startup_ok"] as? Bool ?? true
        metrics.append(ConnectorMetric(
            key: "startup_ok", label: "DOCSIS Init",
            value: startupOK ? 1 : 0,
            unit: startupOK ? "OK" : "FAIL",
            severity: startupOK ? .ok : .critical))

        // ── Events ───────────────────────────────────────────────────────────

        var events: [ConnectorEvent] = []

        // DS signal severity
        let dsSev = json["ds_signal_severity"] as? String ?? "ok"
        if dsSev == "critical" || dsSev == "warning" {
            let sev: MetricSeverity = dsSev == "critical" ? .critical : .warning
            let snrVal = (json["min_snr_db"] as? Double).map { String(format: "%.1f dB", $0) } ?? "–"
            events.append(ConnectorEvent(
                timestamp: Date(), type: "signal_degraded",
                description: "Downstream signal degraded — min SNR \(snrVal)",
                severity: sev))
        }

        // US signal severity
        let usSev = json["us_signal_severity"] as? String ?? "ok"
        if usSev == "critical" || usSev == "warning" {
            let sev: MetricSeverity = usSev == "critical" ? .critical : .warning
            let pwrVal = (json["avg_us_power_dbmv"] as? Double).map { String(format: "%.1f dBmV", $0) } ?? "–"
            events.append(ConnectorEvent(
                timestamp: Date(), type: "upstream_high_power",
                description: "Upstream TX power elevated (\(pwrVal)) — possible signal loss upstream",
                severity: sev))
        }

        // DOCSIS init failure
        if !startupOK {
            events.append(ConnectorEvent(
                timestamp: Date(), type: "docsis_init_fail",
                description: "DOCSIS initialization step failed",
                severity: .critical))
        }

        // Uncorrectable codewords (any > 0 is notable)
        if totalUncorr > 0 {
            events.append(ConnectorEvent(
                timestamp: Date(), type: "uncorrectable_codewords",
                description: "\(totalUncorr) uncorrectable codeword(s) across all DS channels — signal impairment",
                severity: uncorrSev))
        }

        // Modem diagnostic messages and error events
        // The CM3000 emits DOCSIS event log messages using its OWN conservative thresholds
        // (e.g. "SNR is poor at 43 dB" when DOCSIS spec minimum is 30 dB). NetWatch
        // overrides these with DOCSIS-spec-based severity so they don't produce misleading
        // .warning dots when signal is actually fine per spec.
        if let errorEvents = json["error_events"] as? [[String: Any]], !errorEvents.isEmpty {
            for ev in errorEvents.prefix(8) {
                let evType = ev["type"] as? String ?? "modem_error"
                let text   = ev["message"] as? String
                           ?? ev.values.compactMap { $0 as? String }.joined(separator: " ")
                guard !text.isEmpty else { continue }

                let lc = text.lowercased()
                // True critical events — timing failures, sync loss, ranging abort
                let isCritical = lc.contains("t4 timeout")
                             || lc.contains("t3 timeout")
                             || lc.contains("lost sync")
                             || lc.contains("ranging aborted")
                             || lc.contains("registration failed")
                             || evType == "partial_service"

                // Modem's internal SNR/power warnings use conservative thresholds that
                // do not align with the DOCSIS spec. Reclassify to .info.
                let isModemThresholdWarning = !isCritical && (
                    (lc.contains("snr") && (lc.contains("poor") || lc.contains("low") || lc.contains("warn")))
                    || lc.contains("rx power") && lc.contains("out of range")
                    || lc.contains("tx power") && lc.contains("warn")
                )

                let sev: MetricSeverity = isCritical ? .critical
                    : (isModemThresholdWarning ? .info : .warning)

                events.append(ConnectorEvent(
                    timestamp: Date(), type: evType,
                    description: text,
                    severity: sev))
            }
        }

        // ── Summary ──────────────────────────────────────────────────────────

        let model    = json["model"]           as? String ?? "CM3000"
        let firmware = json["firmware"]        as? String ?? ""
        let fwStr    = firmware.isEmpty ? "" : " · FW \(firmware)"
        let avgSNR   = json["avg_snr_db"]      as? Double
        let snrStr   = avgSNR.map { String(format: "avg SNR %.1f dB", $0) } ?? "SNR –"
        let uncorrStr = totalUncorr > 0 ? " · \(totalUncorr) uncorr" : ""
        let summary  = "\(model)\(fwStr) · \(dsTotal) DS / \(usTotal) US · \(snrStr)\(uncorrStr)"

        let snapshot = ConnectorSnapshot(
            connectorId: id, connectorName: displayName,
            timestamp: Date(), metrics: metrics, events: events, summary: summary)

        isConnected  = true
        lastError    = nil
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: - Per-Channel Data Access

    /// Returns the raw per-channel arrays from the last snapshot's source JSON,
    /// used by CM3000ChannelTableView.
    var lastDownstreamChannels: [[String: Any]] {
        // Stored as ConnectorMetric extras aren't ideal for tabular channel data;
        // the view should call fetchSnapshot() directly or ConnectorManager should
        // cache the raw JSON. For now, re-expose via lastSnapshot summary parsing.
        // Full per-channel UI is wired in Sprint 7.
        return []
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

    // Resume-once gated Process wrapper. Writes stdout to a temp file to avoid the
    // 64 KB pipe-buffer deadlock that occurs when scripts produce large JSON output.
    private func runProcess(executable: String, arguments: [String], timeoutSec: Double) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Stdout → temp file (no pipe-buffer size limit)
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("netwatch-cm3000-\(UUID().uuidString).json")
            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
            guard let stdoutHandle = try? FileHandle(forWritingTo: tmpURL) else {
                continuation.resume(throwing: ConnectorError.parseError("Cannot create temp file"))
                return
            }

            let process    = Process()
            let stderrPipe = Pipe()

            process.executableURL  = URL(fileURLWithPath: executable)
            process.arguments      = arguments
            process.standardOutput = stdoutHandle
            process.standardError  = stderrPipe

            var env = ProcessInfo.processInfo.environment
            if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
            process.environment = env

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
                resumeOnce(.failure(ConnectorError.parseError("CM3000 script timed out after \(Int(timeoutSec))s")))
            }
            timer.resume()

            process.terminationHandler = { _ in
                timer.cancel()
                stdoutHandle.closeFile()
                let out = (try? String(contentsOf: tmpURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: tmpURL)
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
                stdoutHandle.closeFile()
                try? FileManager.default.removeItem(at: tmpURL)
                timer.cancel()
                resumeOnce(.failure(error))
            }
        }
    }
}
