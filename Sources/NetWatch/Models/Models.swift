import Foundation

// MARK: - Ping

struct PingTarget: Identifiable, Codable, Hashable {
    var id: String { host }
    var host: String
    var label: String?

    var displayName: String { label ?? host }
}

struct PingResult: Identifiable {
    let id = UUID()
    let timestamp: Date
    let host: String
    let rtt: Double?          // nil = failure
    let success: Bool
}

class PingState: ObservableObject, Identifiable {
    let target: PingTarget
    @Published var results: [PingResult] = []
    @Published var isOnline: Bool = true

    init(target: PingTarget) { self.target = target }

    var id: String { target.id }

    var lastRTT: Double? { results.last?.rtt }

    var avgRTT: Double? {
        let rtts = results.suffix(10).compactMap(\.rtt)
        guard !rtts.isEmpty else { return nil }
        return rtts.reduce(0, +) / Double(rtts.count)
    }

    var successRate: Double {
        let window = results.suffix(20)
        guard !window.isEmpty else { return 1.0 }
        return Double(window.filter(\.success).count) / Double(window.count)
    }

    var trend: Trend {
        let recent = results.suffix(3).compactMap(\.rtt)
        guard recent.count >= 2 else { return .unknown }
        let delta = recent.last! - recent.first!
        if delta > 5 { return .rising }
        if delta < -5 { return .falling }
        return .stable
    }

    var minRTT: Double? { results.compactMap(\.rtt).min() }
    var maxRTT: Double? { results.compactMap(\.rtt).max() }

    /// Population stddev of last 20 RTTs — measures jitter
    var jitter: Double? {
        let rtts = results.suffix(20).compactMap(\.rtt)
        guard rtts.count >= 2 else { return nil }
        let avg = rtts.reduce(0, +) / Double(rtts.count)
        let variance = rtts.map { pow($0 - avg, 2) }.reduce(0, +) / Double(rtts.count)
        return sqrt(variance)
    }

    /// Recent successful RTTs for sparkline rendering
    var recentRTTs: [Double] { results.suffix(15).compactMap(\.rtt) }

    // MARK: Percentiles (over all collected samples)
    var p50: Double? { percentile(50) }
    var p95: Double? { percentile(95) }
    var p99: Double? { percentile(99) }

    private func percentile(_ p: Int) -> Double? {
        let sorted = results.compactMap(\.rtt).sorted()
        guard !sorted.isEmpty else { return nil }
        let idx = max(0, min(sorted.count - 1,
                             Int(Double(sorted.count - 1) * Double(p) / 100.0)))
        return sorted[idx]
    }
}

enum Trend { case rising, falling, stable, unknown
    var symbol: String {
        switch self { case .rising: "↑"; case .falling: "↓"; case .stable: "→"; case .unknown: "–" }
    }
    var color: String {
        switch self { case .rising: "red"; case .falling: "green"; case .stable: "primary"; case .unknown: "secondary" }
    }
}

// MARK: - DNS

struct DNSTarget: Identifiable, Codable, Hashable {
    var id: String { domain }
    var domain: String
}

struct DNSResult: Identifiable {
    let id = UUID()
    let timestamp: Date
    let domain: String
    let queryTime: Double?   // ms, nil = failure
    let status: String       // NOERROR, SERVFAIL, etc.
    var success: Bool { status == "NOERROR" }
}

class DNSState: ObservableObject, Identifiable {
    let target: DNSTarget
    @Published var results: [DNSResult] = []

    init(target: DNSTarget) { self.target = target }

    var id: String { target.id }

    var lastQueryTime: Double? { results.last?.queryTime }

    var avgQueryTime: Double? {
        let times = results.suffix(10).compactMap(\.queryTime)
        guard !times.isEmpty else { return nil }
        return times.reduce(0, +) / Double(times.count)
    }

    var successRate: Double {
        let window = results.suffix(20)
        guard !window.isEmpty else { return 1.0 }
        return Double(window.filter(\.success).count) / Double(window.count)
    }

    var lastStatus: String { results.last?.status ?? "–" }

    /// Per-resolver query time comparison: [resolver label: ms or nil]
    @Published var resolverTimes: [String: Double?] = [:]
}

// MARK: - Link Flap

struct LinkFlap: Identifiable {
    let id   = UUID()
    let timestamp: Date
    let event: String   // "down" or "up"
}

// MARK: - Geo Info (traceroute hop enrichment)

struct GeoInfo {
    let asn:     String   // e.g. "AS13335 Cloudflare"
    let city:    String
    let country: String
    var asnShort: String {
        // "AS13335 Cloudflare, Inc." → "AS13335"
        asn.components(separatedBy: " ").first ?? asn
    }
    var location: String {
        let parts = [city, country].filter { !$0.isEmpty }
        return parts.isEmpty ? "–" : parts.joined(separator: ", ")
    }
}

// MARK: - Interface Stats

struct InterfaceSnapshot: Identifiable {
    let id = UUID()
    let timestamp: Date
    let interface: String
    let rxBytes: Int64
    let txBytes: Int64
    let rxPackets: Int64
    let txPackets: Int64
    let rxErrors: Int64
    let txErrors: Int64
}

struct InterfaceRate {
    let rxBytesPerSec: Double
    let txBytesPerSec: Double
    let rxPacketsPerSec: Double
    let txPacketsPerSec: Double
    let rxErrors: Int64
    let txErrors: Int64
}

struct BandwidthSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let rxBytesPerSec: Double
    let txBytesPerSec: Double
}

// MARK: - Traceroute

struct TracerouteHop: Identifiable {
    let id: Int           // hop number
    let host: String?
    let ip: String?
    let rtt1: Double?
    let rtt2: Double?
    let rtt3: Double?
    var avgRTT: Double? {
        let vals = [rtt1, rtt2, rtt3].compactMap { $0 }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }
    var isTimeout: Bool { rtt1 == nil && rtt2 == nil && rtt3 == nil }
}

struct TracerouteResult {
    let target: String
    let hops: [TracerouteHop]
    let timestamp: Date
    var hopCount: Int { hops.last { !$0.isTimeout }?.id ?? hops.count }
}

// MARK: - Incidents

struct Incident: Identifiable {
    let id: UUID
    let timestamp: Date
    let reason: String
    let subject: String
    let bundlePath: URL
    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: timestamp)
    }
}

// MARK: - App Settings

struct MonitorSettings: Codable {
    var pingTargets: [PingTarget] = [
        PingTarget(host: "1.1.1.1"),
        PingTarget(host: "8.8.8.8"),
        PingTarget(host: "9.9.9.9"),
        PingTarget(host: "208.67.222.222"),
        PingTarget(host: "71.10.216.1", label: "Spectrum DNS 1"),
        PingTarget(host: "71.10.216.2", label: "Spectrum DNS 2"),
    ]
    var dnsTargets: [DNSTarget] = [
        DNSTarget(domain: "github.com"),
        DNSTarget(domain: "google.com"),
        DNSTarget(domain: "cloudflare.com"),
        DNSTarget(domain: "zoom.us"),
        DNSTarget(domain: "apple.com"),
        DNSTarget(domain: "spectrum.net"),
    ]
    var tracerouteTargets: [String] = ["1.1.1.1", "us04web.zoom.us"]
    var pingIntervalSeconds: Double = 1.0
    var dnsIntervalSeconds: Double = 30.0
    var tracerouteIntervalSeconds: Double = 60.0
    var interfaceSampleIntervalSeconds: Double = 0.5
    var pingFailThreshold: Int = 3
    var dnsFailThreshold: Int = 2
    var incidentCooldownSeconds: Double = 60.0
    var networkInterface: String = ""   // empty = auto-detect
    var baseDirectory: String = "~/network_tests"

    /// Device connector configurations. One entry per registered connector;
    /// the `enabled` flag controls whether ConnectorManager instantiates it.
    var connectorConfigs: [ConnectorConfig] = []

    // MARK: Alerting (Sprint 8)

    /// Slack or generic HTTP webhook URL. Empty = alerting disabled.
    var webhookURL: String = ""

    /// Fire a webhook when the network health score drops below this value (0 = disabled).
    var alertOnHealthScoreBelow: Int = 0

    /// Weekly bandwidth budget in GB across all connectors (0 = disabled).
    var weeklyBandwidthBudgetGB: Double = 0

    /// Alert again when this many hours have elapsed since the last bandwidth alert (0 = each poll).
    var bandwidthAlertCooldownHours: Double = 24

    /// Fire a webhook when speed test download drops below this Mbps (0 = disabled).
    var speedTestAlertThresholdMbps: Double = 0

    // MARK: Mobile API (Sprint 9)

    /// Enable the local HTTP API server for NetWatch Mobile.
    var mobileAPIEnabled: Bool = false

    /// Port for the local HTTP API server (default 57821).
    var mobileAPIPort: UInt16 = 57_821

    // MARK: Remediation (Sprint 11)

    /// Enable automated remediation actions (DNS failover, etc.).
    var remediationEnabled: Bool = false

    /// Consecutive failures required to trigger DNS failover.
    var remediationFailThreshold: Int = 3

    /// Backup DNS servers used during failover.
    var remediationBackupDNS: [String] = ["9.9.9.9", "208.67.222.222"]

    static let `default` = MonitorSettings()

    static func load() -> MonitorSettings {
        guard let data = UserDefaults.standard.data(forKey: "MonitorSettings"),
              let settings = try? JSONDecoder().decode(MonitorSettings.self, from: data)
        else { return .default }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "MonitorSettings")
        }
    }

    /// Returns the config for a given connector id, creating a disabled default if absent.
    mutating func connectorConfig(for id: String) -> ConnectorConfig {
        if let existing = connectorConfigs.first(where: { $0.id == id }) {
            return existing
        }
        let new = ConnectorConfig(id: id)
        connectorConfigs.append(new)
        return new
    }

    /// Upserts a connector config.
    mutating func setConnectorConfig(_ config: ConnectorConfig) {
        if let idx = connectorConfigs.firstIndex(where: { $0.id == config.id }) {
            connectorConfigs[idx] = config
        } else {
            connectorConfigs.append(config)
        }
    }
}

// MARK: - MonitorSettings Codable (custom decoder so new fields never break old saved settings)

extension MonitorSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Pre-existing fields — required; if absent the stored JSON is corrupt → fall back to .default
        pingTargets                    = try c.decode([PingTarget].self,      forKey: .pingTargets)
        dnsTargets                     = try c.decode([DNSTarget].self,       forKey: .dnsTargets)
        tracerouteTargets              = try c.decode([String].self,          forKey: .tracerouteTargets)
        pingIntervalSeconds            = try c.decode(Double.self,            forKey: .pingIntervalSeconds)
        dnsIntervalSeconds             = try c.decode(Double.self,            forKey: .dnsIntervalSeconds)
        tracerouteIntervalSeconds      = try c.decode(Double.self,            forKey: .tracerouteIntervalSeconds)
        interfaceSampleIntervalSeconds = try c.decode(Double.self,            forKey: .interfaceSampleIntervalSeconds)
        pingFailThreshold              = try c.decode(Int.self,               forKey: .pingFailThreshold)
        dnsFailThreshold               = try c.decode(Int.self,               forKey: .dnsFailThreshold)
        incidentCooldownSeconds        = try c.decode(Double.self,            forKey: .incidentCooldownSeconds)
        networkInterface               = try c.decode(String.self,            forKey: .networkInterface)
        baseDirectory                  = try c.decode(String.self,            forKey: .baseDirectory)
        connectorConfigs               = try c.decode([ConnectorConfig].self, forKey: .connectorConfigs)
        // Sprint 8+ fields — use decodeIfPresent so old saved JSON still deserialises cleanly
        webhookURL                   = try c.decodeIfPresent(String.self,  forKey: .webhookURL)                   ?? ""
        alertOnHealthScoreBelow      = try c.decodeIfPresent(Int.self,     forKey: .alertOnHealthScoreBelow)      ?? 0
        weeklyBandwidthBudgetGB      = try c.decodeIfPresent(Double.self,  forKey: .weeklyBandwidthBudgetGB)      ?? 0
        bandwidthAlertCooldownHours  = try c.decodeIfPresent(Double.self,  forKey: .bandwidthAlertCooldownHours)  ?? 24
        // Sprint 10 field
        speedTestAlertThresholdMbps  = try c.decodeIfPresent(Double.self,   forKey: .speedTestAlertThresholdMbps) ?? 0
        // Sprint 11 fields
        remediationEnabled           = try c.decodeIfPresent(Bool.self,     forKey: .remediationEnabled)          ?? false
        remediationFailThreshold     = try c.decodeIfPresent(Int.self,      forKey: .remediationFailThreshold)    ?? 3
        remediationBackupDNS         = try c.decodeIfPresent([String].self, forKey: .remediationBackupDNS)        ?? ["9.9.9.9", "208.67.222.222"]
        // Sprint 9 (Mobile API) fields
        mobileAPIEnabled             = try c.decodeIfPresent(Bool.self,    forKey: .mobileAPIEnabled)             ?? false
        mobileAPIPort                = try c.decodeIfPresent(UInt16.self,  forKey: .mobileAPIPort)                ?? 57_821
    }
}

// MARK: - RTT Formatting

extension Double {
    var rttString: String { String(format: "%.1f ms", self) }
}

extension Optional where Wrapped == Double {
    var rttString: String { self.map { String(format: "%.1f ms", $0) } ?? "–" }
}
