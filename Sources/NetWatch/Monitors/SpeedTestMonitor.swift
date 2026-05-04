/// SpeedTestMonitor.swift — On-demand and scheduled network speed tests
///
/// Uses Apple's built-in `networkQuality` tool (macOS 12+, no external deps).
/// Runs with `-s -v` (sequential mode, verbose JSON output) for reliable
/// per-direction measurements.
///
/// Output fields parsed:
///   dl_throughput        Download in bits/sec
///   ul_throughput        Upload in bits/sec
///   latency              Idle latency in ms
///   responsiveness       RPM (requests per minute — Apple's network responsiveness metric)
///   base_rtt             Base RTT in ms (unloaded)
///   dl_flows             Number of parallel download flows used
///   ul_flows             Number of parallel upload flows used
///
/// Architecture:
///   SpeedTestMonitor is an ObservableObject injected into the SwiftUI environment.
///   runTest() starts an async task; the result is published on @Published properties.
///   History is stored in-memory (rolling 50 samples) and persisted to a JSON file
///   in the NetWatch base directory so it survives app restarts.
///
/// Integration:
///   NetworkMonitorService creates and owns this monitor.
///   SpeedTestView observes it directly.
///   StackDiagnosisEngine reads lastResult to factor into the ISP layer assessment.

import Foundation
import Combine

// MARK: - Speed test result

struct SpeedTestResult: Codable, Identifiable {
    let id:              UUID
    let timestamp:       Date
    let downloadMbps:    Double        ///< Megabits per second
    let uploadMbps:      Double        ///< Megabits per second
    let latencyMs:       Double        ///< Idle round-trip time in ms
    let baseRttMs:       Double        ///< Unloaded RTT in ms (Apple RPM baseline)
    let responsiveness:  Int           ///< RPM — requests per minute (Apple's metric)
    let downloadFlows:   Int           ///< Parallel flows used for DL
    let uploadFlows:     Int           ///< Parallel flows used for UL
    let error:           String?       ///< Non-nil if the test failed

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         downloadMbps: Double = 0,
         uploadMbps: Double = 0,
         latencyMs: Double = 0,
         baseRttMs: Double = 0,
         responsiveness: Int = 0,
         downloadFlows: Int = 0,
         uploadFlows: Int = 0,
         error: String? = nil) {
        self.id             = id
        self.timestamp      = timestamp
        self.downloadMbps   = downloadMbps
        self.uploadMbps     = uploadMbps
        self.latencyMs      = latencyMs
        self.baseRttMs      = baseRttMs
        self.responsiveness = responsiveness
        self.downloadFlows  = downloadFlows
        self.uploadFlows    = uploadFlows
        self.error          = error
    }

    var isSuccess: Bool { error == nil }

    /// Responsiveness quality label (Apple's RPM tiers)
    var responsivenessLabel: String {
        switch responsiveness {
        case 0:        return "–"
        case ..<100:   return "Low"
        case ..<200:   return "Medium"
        default:       return "High"
        }
    }

    /// Overall quality assessment
    var quality: SpeedTestQuality {
        guard isSuccess else { return .error }
        if downloadMbps >= 100 && uploadMbps >= 10 && latencyMs < 50 { return .excellent }
        if downloadMbps >= 25  && uploadMbps >= 3  && latencyMs < 100 { return .good }
        if downloadMbps >= 5   && uploadMbps >= 1                      { return .fair }
        return .poor
    }
}

enum SpeedTestQuality {
    case excellent, good, fair, poor, error

    var label: String {
        switch self {
        case .excellent: return "Excellent"
        case .good:      return "Good"
        case .fair:      return "Fair"
        case .poor:      return "Poor"
        case .error:     return "Error"
        }
    }

    var color: String {
        switch self {
        case .excellent: return "green"
        case .good:      return "blue"
        case .fair:      return "yellow"
        case .poor, .error: return "red"
        }
    }
}

// MARK: - Monitor

@MainActor
final class SpeedTestMonitor: ObservableObject {

    // MARK: - Published

    @Published private(set) var isRunning:   Bool             = false
    @Published private(set) var progress:    String           = ""     ///< Live status text
    @Published private(set) var lastResult:  SpeedTestResult? = nil
    @Published private(set) var history:     [SpeedTestResult] = []    ///< Most-recent first

    // MARK: - Config

    /// Minimum download Mbps below which a webhook alert fires (0 = disabled)
    var alertThresholdMbps: Double = 0

    /// Webhook URL for speed alerts — injected by NetworkMonitorService
    var webhookURL: String = ""

    // MARK: - Private

    private let maxHistory     = 50
    private var persistenceURL: URL?
    private var runningTask:    Task<Void, Never>? = nil

    private static let networkQualityPath = "/usr/bin/networkQuality"

    // MARK: - Init

    init(baseDirectory: String = "~/network_tests") {
        loadHistory(baseDirectory: baseDirectory)
    }

    func setBaseDirectory(_ baseDirectory: String) {
        loadHistory(baseDirectory: baseDirectory)
    }

    // MARK: - Run test

    /// Run a full networkQuality test. Safe to call from any context;
    /// all state updates happen on MainActor.
    func runTest() {
        guard !isRunning else { return }
        runningTask?.cancel()
        runningTask = Task {
            await performTest()
        }
    }

    func cancelTest() {
        runningTask?.cancel()
        runningTask = nil
        isRunning = false
        progress  = ""
    }

    // MARK: - Core

    private func performTest() async {
        isRunning = true
        progress  = "Starting speed test…"

        // Check tool availability
        guard FileManager.default.fileExists(atPath: Self.networkQualityPath) else {
            let result = SpeedTestResult(error: "networkQuality not found at \(Self.networkQualityPath) — requires macOS 12+")
            finalize(result)
            return
        }

        progress = "Measuring download speed…"

        do {
            let output = try await runNetworkQuality()
            let result = parseOutput(output)
            finalize(result)

            // Alert if below threshold
            if let threshold = alertThresholdMbps as Double?,
               threshold > 0,
               result.isSuccess,
               result.downloadMbps < threshold,
               !webhookURL.isEmpty {
                await sendSpeedAlert(result: result, threshold: threshold)
            }
        } catch is CancellationError {
            isRunning = false
            progress  = ""
        } catch {
            let result = SpeedTestResult(error: error.localizedDescription)
            finalize(result)
        }
    }

    private func finalize(_ result: SpeedTestResult) {
        lastResult = result
        isRunning  = false
        progress   = ""
        history.insert(result, at: 0)
        if history.count > maxHistory { history = Array(history.prefix(maxHistory)) }
        saveHistory()
    }

    // MARK: - networkQuality execution

    private func runNetworkQuality() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process    = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL  = URL(fileURLWithPath: Self.networkQualityPath)
            // -s = sequential (DL then UL, more accurate than parallel)
            // -v = verbose JSON output
            process.arguments      = ["-s", "-v", "-c"]  // -c = print JSON to stdout
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            let lock    = NSLock()
            var resumed = false
            func resumeOnce(_ r: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch r {
                case .success(let v): continuation.resume(returning: v)
                case .failure(let e): continuation.resume(throwing: e)
                }
            }

            // Timeout: networkQuality can take 60–90s for sequential mode
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 120)
            timer.setEventHandler {
                process.terminate()
                timer.cancel()
                resumeOnce(.failure(SpeedTestError.timeout))
            }
            timer.resume()

            process.terminationHandler = { p in
                timer.cancel()
                let out  = String(data: stdoutPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                let err  = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    resumeOnce(.success(out))
                } else {
                    let msg = out.isEmpty ? err : out
                    resumeOnce(.failure(SpeedTestError.failed(
                        msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "networkQuality exited \(p.terminationStatus)"
                            : msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    )))
                }
            }

            do {
                try process.run()
                // Update progress on a background task while we wait
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if self.isRunning { self.progress = "Download test in progress…" }
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if self.isRunning { self.progress = "Upload test in progress…" }
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if self.isRunning { self.progress = "Finalising results…" }
                }
            } catch {
                timer.cancel()
                resumeOnce(.failure(error))
            }
        }
    }

    // MARK: - JSON parser

    private func parseOutput(_ raw: String) -> SpeedTestResult {
        // networkQuality -c outputs JSON (one object). May be wrapped in terminal
        // output lines — find the first '{' line.
        let jsonStr: String
        if let braceRange = raw.range(of: "{") {
            jsonStr = String(raw[braceRange.lowerBound...])
        } else {
            return SpeedTestResult(error: "No JSON in networkQuality output: \(raw.prefix(200))")
        }

        guard let data = jsonStr.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SpeedTestResult(error: "Could not parse networkQuality JSON")
        }

        // networkQuality JSON field names vary slightly across macOS versions
        // (12 = dl_throughput, 13+ may use different names — handle both)
        let dlBps  = (obj["dl_throughput"]        as? Double)
                  ?? (obj["download_throughput"]   as? Double)
                  ?? 0
        let ulBps  = (obj["ul_throughput"]        as? Double)
                  ?? (obj["upload_throughput"]     as? Double)
                  ?? 0
        let latMs  = (obj["latency"]              as? Double)
                  ?? (obj["idle_latency"]         as? Double)
                  ?? 0
        let rtt    = (obj["base_rtt"]             as? Double)
                  ?? (obj["loaded_rtt"]           as? Double)
                  ?? 0
        let rpm    = (obj["responsiveness"]       as? Int)
                  ?? (obj["rpm"]                  as? Int)
                  ?? 0
        let dlFlow = (obj["dl_flows"]             as? Int) ?? 0
        let ulFlow = (obj["ul_flows"]             as? Int) ?? 0

        guard dlBps > 0 || ulBps > 0 else {
            return SpeedTestResult(error: "networkQuality returned zero throughput — test may have failed")
        }

        return SpeedTestResult(
            downloadMbps:   dlBps / 1_000_000,
            uploadMbps:     ulBps / 1_000_000,
            latencyMs:      latMs,
            baseRttMs:      rtt,
            responsiveness: rpm,
            downloadFlows:  dlFlow,
            uploadFlows:    ulFlow
        )
    }

    // MARK: - Persistence

    private func loadHistory(baseDirectory: String) {
        let base    = (baseDirectory as NSString).expandingTildeInPath
        // Resolve any symlink before constructing paths — `String.write(to:atomically:true)` and
        // `FileManager.createDirectory` fail silently when the destination passes through a symlink
        // (same fix applied to IncidentManager). `resolvingSymlinksInPath()` follows the chain.
        let rawDir  = URL(fileURLWithPath: base).appendingPathComponent("speed_tests")
        let dir     = rawDir.resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.json")
        persistenceURL = url
        guard let data   = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([SpeedTestResult].self, from: data)
        else { return }
        history    = Array(loaded.prefix(maxHistory))
        lastResult = history.first
    }

    private func saveHistory() {
        guard let url  = persistenceURL,
              let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url)
    }

    // MARK: - Webhook alert

    private func sendSpeedAlert(result: SpeedTestResult, threshold: Double) async {
        guard let url = URL(string: webhookURL) else { return }
        let payload: [String: Any] = [
            "text": String(format: "⚠️ NetWatch Speed Alert: Download %.1f Mbps (threshold %.0f Mbps) · Upload %.1f Mbps · Latency %.0f ms",
                           result.downloadMbps, threshold, result.uploadMbps, result.latencyMs)
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody   = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try? await URLSession.shared.data(for: req)
    }

    // MARK: - History helpers

    var recentDownloadMbps: [Double] {
        history.prefix(20).compactMap { $0.isSuccess ? $0.downloadMbps : nil }.reversed()
    }

    var recentUploadMbps: [Double] {
        history.prefix(20).compactMap { $0.isSuccess ? $0.uploadMbps : nil }.reversed()
    }

    var avgDownloadMbps: Double? {
        let vals = history.prefix(10).compactMap { $0.isSuccess ? $0.downloadMbps : nil }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    var avgUploadMbps: Double? {
        let vals = history.prefix(10).compactMap { $0.isSuccess ? $0.uploadMbps : nil }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }
}

// MARK: - Errors

enum SpeedTestError: Error, LocalizedError {
    case timeout
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:       return "Speed test timed out (>120s)"
        case .failed(let m): return m
        }
    }
}
