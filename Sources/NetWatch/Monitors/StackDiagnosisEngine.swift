/// StackDiagnosisEngine.swift — Cross-device root-cause layering for NetWatch
///
/// Takes a snapshot of all active data sources (ping, DNS, traceroute, and every
/// device connector) and walks the network stack from the ISP down to the local
/// mesh, isolating the deepest layer that shows degradation. Produces a numeric
/// health score (0–100), a root-cause layer, confidence rating, per-layer
/// evidence, and human-readable recommendations — all without requiring internet
/// access or external services.
///
/// Stack order (outermost → innermost):
///   .internet → .isp → .modem → .firewall → .mesh → .client
///
/// Integration: call StackDiagnosisEngine.diagnose(...) from IncidentManager
/// (and optionally from periodic health-check polling) to annotate incidents.

import Foundation

// MARK: - Public types

/// A single network stack layer.
enum StackLayer: String, CaseIterable {
    case internet = "Internet"
    case isp      = "ISP / WAN"
    case modem    = "Cable Modem"
    case firewall = "Firewall"
    case mesh     = "Mesh Network"
    case client   = "Local Client"
    case unknown  = "Unknown"

    /// Ordered from outermost to innermost.
    static var stackOrder: [StackLayer] {
        [.internet, .isp, .modem, .firewall, .mesh, .client]
    }
}

/// Coarse health rating for a single layer.
enum LayerStatus: String {
    case healthy  = "healthy"
    case degraded = "degraded"
    case critical = "critical"
    case unknown  = "unknown"

    var score: Int {
        switch self {
        case .healthy:  return 100
        case .degraded: return 55
        case .critical: return 10
        case .unknown:  return 50
        }
    }
}

/// How certain we are about the root-cause identification.
enum DiagnosisConfidence: String {
    case high   = "high"
    case medium = "medium"
    case low    = "low"
}

/// Assessment of a single stack layer.
struct LayerResult {
    let layer:     StackLayer
    let status:    LayerStatus
    let evidence:  [String]    ///< Human-readable signals that drove this assessment
    let score:     Int         ///< 0–100 contribution (used in overall health score)
}

/// Full diagnosis produced by StackDiagnosisEngine.diagnose().
struct StackDiagnosis {
    let timestamp:    Date
    let healthScore:  Int                ///< 0–100 (100 = fully healthy)
    let rootCause:    StackLayer         ///< Deepest layer in distress (or .unknown)
    let confidence:   DiagnosisConfidence
    let summary:      String             ///< One-sentence human-readable conclusion
    let layerResults: [LayerResult]      ///< One per layer in stackOrder
    let recommendations: [String]        ///< Actionable next steps

    /// Formatted multi-line text report, suitable for incident bundle files.
    func report() -> String {
        var lines: [String] = []
        lines.append("=== Stack Diagnosis — \(timestamp) ===")
        lines.append(String(format: "Health Score : %d/100", healthScore))
        lines.append("Root Cause   : \(rootCause.rawValue)")
        lines.append("Confidence   : \(confidence.rawValue)")
        lines.append("Summary      : \(summary)")
        lines.append("")
        lines.append("Layer breakdown:")
        for lr in layerResults {
            let bar = String(repeating: "█", count: lr.score / 10)
                    + String(repeating: "░", count: 10 - lr.score / 10)
            lines.append(String(format: "  %-16s  %-9s  %@  %d",
                lr.layer.rawValue as NSString,
                lr.status.rawValue as NSString,
                bar, lr.score))
            for ev in lr.evidence {
                lines.append("    • \(ev)")
            }
        }
        if !recommendations.isEmpty {
            lines.append("")
            lines.append("Recommendations:")
            for r in recommendations {
                lines.append("  → \(r)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Engine

struct StackDiagnosisEngine {

    // MARK: - Entry point

    static func diagnose(
        pingStates:  [PingState],
        dnsStates:   [DNSState],
        traceroute:  TracerouteResult?,
        snapshots:   [ConnectorSnapshot]
    ) -> StackDiagnosis {

        // Partition connector snapshots by well-known connector IDs
        let firewalla = snapshots.first { $0.connectorId == "firewalla" }
        let cm3000    = snapshots.first { $0.connectorId == "cm3000"    }
        let orbi      = snapshots.first { $0.connectorId == "orbi"      }
        // Nighthawk is a second router/switch — treat like mesh for stack purposes

        // ── Layer assessments ─────────────────────────────────────────────────

        let internetLayer  = assessInternet(pingStates: pingStates,
                                            dnsStates: dnsStates,
                                            traceroute: traceroute)
        let ispLayer       = assessISP(pingStates: pingStates,
                                       firewalla: firewalla,
                                       cm3000: cm3000)
        let modemLayer     = assessModem(cm3000: cm3000)
        let firewallLayer  = assessFirewall(firewalla: firewalla)
        let meshLayer      = assessMesh(orbi: orbi)
        let clientLayer    = assessClient(pingStates: pingStates)

        let layers: [LayerResult] = [internetLayer, ispLayer, modemLayer,
                                     firewallLayer, meshLayer, clientLayer]

        // ── Root cause: innermost (deepest toward user) critical/degraded layer ─
        // When no layer is degraded/critical, there is no root cause — use .unknown
        // so the UI suppresses the root-cause badge. This prevents "Internet ← Root Cause"
        // appearing on a fully-healthy network.
        let problematic = layers.reversed().first {
            $0.status == .critical || $0.status == .degraded
        }
        let rootResult: LayerResult
        if let p = problematic {
            rootResult = p
        } else {
            // No degraded or critical layers — no identifiable root cause.
            rootResult = LayerResult(layer: .unknown, status: .healthy, evidence: [], score: 100)
        }

        // ── Health score ─────────────────────────────────────────────────────
        // Weighted average: modem + firewall + ISP are higher-weight than mesh/client
        let weights: [StackLayer: Double] = [
            .internet: 1.0,
            .isp:      1.5,
            .modem:    1.5,
            .firewall: 1.2,
            .mesh:     1.0,
            .client:   0.8,
            .unknown:  1.0
        ]
        var weightSum = 0.0
        var scoreSum  = 0.0
        for lr in layers {
            let w = weights[lr.layer] ?? 1.0
            weightSum += w
            scoreSum  += Double(lr.score) * w
        }
        // Additional deductions from raw probe data
        var rawDeduction = 0
        let overallPingLoss = avgPingLoss(pingStates)
        rawDeduction += min(30, Int(overallPingLoss * 100))    // up to -30 for ping loss
        let overallDNSFail = avgDNSFailure(dnsStates)
        if overallDNSFail > 0.5 { rawDeduction += 20 }         // -20 for >50% DNS failure

        let rawScore = Int(scoreSum / max(1, weightSum))
        let healthScore = max(0, min(100, rawScore - rawDeduction))

        // ── Confidence ────────────────────────────────────────────────────────
        let knownLayerCount = layers.filter { $0.status != .unknown }.count
        let confidence: DiagnosisConfidence
        switch knownLayerCount {
        case 5...: confidence = .high
        case 3..<5: confidence = .medium
        default:    confidence = .low
        }

        // ── Summary sentence ──────────────────────────────────────────────────
        let summary = makeSummary(rootResult: rootResult,
                                  healthScore: healthScore,
                                  layers: layers)

        // ── Recommendations ───────────────────────────────────────────────────
        let recommendations = makeRecommendations(rootCause: rootResult.layer,
                                                  layers: layers,
                                                  cm3000: cm3000,
                                                  firewalla: firewalla)

        return StackDiagnosis(
            timestamp:       Date(),
            healthScore:     healthScore,
            rootCause:       rootResult.layer,
            confidence:      confidence,
            summary:         summary,
            layerResults:    layers,
            recommendations: recommendations
        )
    }

    // MARK: - Layer assessors

    private static func assessInternet(pingStates: [PingState],
                                       dnsStates: [DNSState],
                                       traceroute: TracerouteResult?) -> LayerResult {
        var evidence: [String] = []
        var status: LayerStatus = .healthy

        let dnsFailRate = avgDNSFailure(dnsStates)
        if dnsFailRate > 0.8 {
            evidence.append(String(format: "DNS failure rate %.0f%% (likely ISP DNS or internet routing)", dnsFailRate * 100))
            status = .critical
        } else if dnsFailRate > 0.3 {
            evidence.append(String(format: "DNS failure rate %.0f%%", dnsFailRate * 100))
            status = .degraded
        } else if dnsFailRate == 0, !dnsStates.isEmpty {
            evidence.append("DNS resolving normally")
        }

        // Traceroute: if it runs out of responses in the middle with no loop back
        if let tr = traceroute {
            let timeouts = tr.hops.filter { $0.avgRTT == nil }.count
            let total    = tr.hops.count
            if total > 3, timeouts > total / 2 {
                evidence.append("Traceroute: \(timeouts)/\(total) hops unresponsive — possible routing blackhole")
                if status != .critical { status = .degraded }
            } else if total > 0 {
                let lastResponding = tr.hops.last { $0.avgRTT != nil }
                let hopStr = lastResponding.map { String(format: "%.1fms at hop %d", $0.avgRTT ?? 0, $0.id) } ?? "none"
                evidence.append("Traceroute reached \(hopStr)")
            }
        }

        // High DNS latency as soft signal
        let slowDNS = dnsStates.filter { ($0.lastQueryTime ?? 0) > 500 }
        if !slowDNS.isEmpty {
            evidence.append("High DNS latency (>\(500)ms) on \(slowDNS.count) resolver(s)")
            if status == .healthy { status = .degraded }
        }

        if evidence.isEmpty { status = .unknown }
        let score = status == .healthy ? 100 : (status == .degraded ? 55 : (status == .critical ? 10 : 50))
        return LayerResult(layer: .internet, status: status, evidence: evidence, score: score)
    }

    private static func assessISP(pingStates: [PingState],
                                  firewalla: ConnectorSnapshot?,
                                  cm3000: ConnectorSnapshot?) -> LayerResult {
        var evidence: [String] = []
        var score = 100
        var status: LayerStatus = .unknown

        // Firewalla WAN state
        if let fw = firewalla {
            let wanMetrics = fw.metrics.filter { $0.key.hasPrefix("wan_") && !$0.key.contains("ip") }
            let anyActive  = wanMetrics.contains { $0.severity == .ok }
            let anyDown    = wanMetrics.contains { $0.severity == .critical }
            if anyActive {
                evidence.append("Firewalla WAN interface active")
                status = .healthy
            } else if anyDown {
                evidence.append("Firewalla: no active WAN interface")
                score  -= 60
                status  = .critical
            }
            // Public IP present
            if let pubIP = fw.metrics.first(where: { $0.key == "public_ip" }), !pubIP.unit.isEmpty {
                evidence.append("Public IP: \(pubIP.unit)")
            }
        }

        // CM3000 upstream signal (high TX power → line attenuation → ISP-side)
        if let cm = cm3000 {
            if let usPwr = cm.metrics.first(where: { $0.key == "avg_us_power" }) {
                if usPwr.severity == .critical {
                    evidence.append(String(format: "CM3000 upstream TX power critical (%.1f dBmV) — line attenuation", usPwr.value))
                    score  -= 35
                    status  = max(status, .critical)
                } else if usPwr.severity == .warning {
                    evidence.append(String(format: "CM3000 upstream TX power elevated (%.1f dBmV)", usPwr.value))
                    score  -= 15
                    status  = max(status, .degraded)
                }
            }
        }

        // External ping loss to WAN targets (8.8.8.8, 1.1.1.1)
        let wanPings = pingStates.filter { isPublicIP($0.target.host) }
        let wanLoss  = avgPingLoss(wanPings)
        if !wanPings.isEmpty {
            if wanLoss > 0.5 {
                evidence.append(String(format: "WAN ping loss %.0f%%", wanLoss * 100))
                score  -= Int(wanLoss * 40)
                status  = max(status, .critical)
            } else if wanLoss > 0.1 {
                evidence.append(String(format: "WAN ping loss %.0f%%", wanLoss * 100))
                score  -= Int(wanLoss * 25)
                status  = max(status, .degraded)
            } else if wanLoss == 0 {
                evidence.append("No WAN ping loss")
                status  = max(status, .healthy)
            }
        }

        score = max(0, score)
        if evidence.isEmpty { status = .unknown; score = 50 }
        return LayerResult(layer: .isp, status: status, evidence: evidence, score: score)
    }

    private static func assessModem(cm3000: ConnectorSnapshot?) -> LayerResult {
        guard let cm = cm3000 else {
            return LayerResult(layer: .modem, status: .unknown,
                               evidence: ["No CM3000 data (connector not configured or unreachable)"],
                               score: 50)
        }
        var evidence: [String] = []
        var score = 100

        // DOCSIS startup
        if let startup = cm.metrics.first(where: { $0.key == "startup_ok" }) {
            if startup.value == 0 {
                evidence.append("DOCSIS initialization FAILED")
                score -= 50
            } else {
                evidence.append("DOCSIS initialization OK")
            }
        }

        // Downstream SNR
        if let snr = cm.metrics.first(where: { $0.key == "avg_snr_db" }) {
            let s = String(format: "%.1f dB", snr.value)
            if snr.severity == .critical {
                evidence.append("DS SNR critical (\(s) < 33 dB)")
                score -= 35
            } else if snr.severity == .warning {
                evidence.append("DS SNR marginal (\(s) < 38 dB)")
                score -= 15
            } else {
                evidence.append("DS SNR good (\(s))")
            }
        }

        // Uncorrectable codewords
        if let uncorr = cm.metrics.first(where: { $0.key == "total_uncorr_codewords" }) {
            let n = Int(uncorr.value)
            if n > 0 {
                let deduction = min(30, n / 10 + 10)
                evidence.append("\(n) uncorrectable codeword(s) — signal impairment on cable plant")
                score -= deduction
            } else {
                evidence.append("No uncorrectable codewords — signal clean")
            }
        }

        // Downstream receive power
        if let dsPwr = cm.metrics.first(where: { $0.key == "avg_ds_power" }) {
            if dsPwr.severity == .critical {
                evidence.append(String(format: "DS receive power out of range (%.1f dBmV)", dsPwr.value))
                score -= 20
            } else if dsPwr.severity == .warning {
                evidence.append(String(format: "DS receive power marginal (%.1f dBmV)", dsPwr.value))
                score -= 8
            }
        }

        score = max(0, score)
        let status: LayerStatus = score >= 85 ? .healthy : (score >= 50 ? .degraded : .critical)
        return LayerResult(layer: .modem, status: status, evidence: evidence, score: score)
    }

    private static func assessFirewall(firewalla: ConnectorSnapshot?) -> LayerResult {
        guard let fw = firewalla else {
            return LayerResult(layer: .firewall, status: .unknown,
                               evidence: ["No Firewalla data (SSH unreachable or connector not configured)"],
                               score: 50)
        }
        var evidence: [String] = []
        var score = 100

        // Active alarms
        if let alarmMetric = fw.metrics.first(where: { $0.key == "active_alarms" }) {
            let count = Int(alarmMetric.value)
            if count > 5 {
                evidence.append("\(count) active alarms on Firewalla")
                score -= 20
            } else if count > 0 {
                evidence.append("\(count) active alarm(s)")
                score -= 8
            } else {
                evidence.append("No active alarms")
            }
        }

        // Cyber events in recent alarms (from events array)
        let cyberEvents = fw.events.filter { $0.type == "alarm" && $0.severity == .critical }
        if !cyberEvents.isEmpty {
            evidence.append("\(cyberEvents.count) critical security alarm(s)")
            score -= 15
        }

        // WAN uptime
        if let uptime = fw.metrics.first(where: { $0.key == "uptime_h" }) {
            let h = uptime.value
            if h > 0 && h < (5.0 / 60.0) {
                evidence.append("Firewalla recently rebooted (uptime < 5 min)")
                score -= 10
            } else if h > 0 {
                evidence.append(String(format: "Firewalla uptime %.1f h", h))
            }
        }

        // VPN tunnels (informational — healthy if present)
        if let vpn = fw.metrics.first(where: { $0.key == "vpn_tunnels" }) {
            evidence.append("\(Int(vpn.value)) active VPN tunnel(s)")
        }

        score = max(0, score)
        let status: LayerStatus = score >= 85 ? .healthy : (score >= 55 ? .degraded : .critical)
        return LayerResult(layer: .firewall, status: status, evidence: evidence, score: score)
    }

    private static func assessMesh(orbi: ConnectorSnapshot?) -> LayerResult {
        guard let orbi = orbi else {
            return LayerResult(layer: .mesh, status: .unknown,
                               evidence: ["No Orbi data (connector not configured or unreachable)"],
                               score: 50)
        }
        var evidence: [String] = []
        var score = 100

        // Client count
        if let clients = orbi.metrics.first(where: { $0.key == "total_clients" }) {
            let n = Int(clients.value)
            evidence.append("\(n) client(s) connected")
            if n == 0 { score -= 20 }
        }

        // Satellite node count vs offline events
        if let satellites = orbi.metrics.first(where: { $0.key == "satellite_nodes" }) {
            evidence.append("\(Int(satellites.value)) satellite node(s) detected")
        }
        let offlineEvents = orbi.events.filter { $0.type == "satellite_offline" }
        if !offlineEvents.isEmpty {
            evidence.append("\(offlineEvents.count) satellite(s) offline")
            score -= offlineEvents.count * 15
        }

        // Firmware update available
        let fwUpdateEvents = orbi.events.filter { $0.type == "firmware_update" }
        if !fwUpdateEvents.isEmpty {
            evidence.append("Orbi firmware update available")
            score -= 5   // informational, minor
        }

        score = max(0, score)
        let status: LayerStatus = score >= 85 ? .healthy : (score >= 55 ? .degraded : .critical)
        return LayerResult(layer: .mesh, status: status, evidence: evidence, score: score)
    }

    private static func assessClient(pingStates: [PingState]) -> LayerResult {
        var evidence: [String] = []
        var score = 100

        // LAN gateway pings (192.168.x.x, 10.x.x.x, 172.16.x.x targets)
        let lanPings   = pingStates.filter { isPrivateIP($0.target.host) }
        let wanPings   = pingStates.filter { isPublicIP($0.target.host) }
        let lanLoss    = avgPingLoss(lanPings)

        if !lanPings.isEmpty {
            // Direct LAN evidence — most reliable
            if lanLoss > 0.3 {
                evidence.append(String(format: "LAN ping loss %.0f%% — local routing or NIC issue", lanLoss * 100))
                score -= Int(lanLoss * 50)
            } else if lanLoss == 0 {
                evidence.append("LAN gateway reachable (0% packet loss)")
            }
        } else {
            // No LAN targets configured — infer from WAN reachability
            // If the machine can reach the internet, it obviously has a working local stack
            let wanReachable = !wanPings.isEmpty && avgPingLoss(wanPings) < 0.3
            if wanReachable {
                let onlineCount = wanPings.filter { $0.isOnline }.count
                evidence.append("No LAN targets configured — inferred healthy (\(onlineCount) WAN target(s) reachable)")
                // score stays at 100, return healthy so client never false-badges as root cause
                return LayerResult(layer: .client, status: .healthy, evidence: evidence, score: 95)
            } else if !wanPings.isEmpty {
                // WAN also failing → client MAY be the problem, but ISP/modem layers
                // will catch this — keep unknown so engine looks elsewhere
                evidence.append("No LAN targets configured and WAN unreachable — cannot assess local stack")
                return LayerResult(layer: .client, status: .unknown, evidence: evidence, score: 50)
            } else {
                evidence.append("No ping targets configured")
                return LayerResult(layer: .client, status: .unknown, evidence: evidence, score: 50)
            }
        }

        score = max(0, score)
        let status: LayerStatus = score >= 85 ? .healthy : (score >= 55 ? .degraded : .critical)
        return LayerResult(layer: .client, status: status, evidence: evidence, score: score)
    }

    // MARK: - Summary and recommendations

    private static func makeSummary(rootResult: LayerResult,
                                    healthScore: Int,
                                    layers: [LayerResult]) -> String {
        if healthScore >= 90 {
            return "Network stack fully healthy (score \(healthScore)/100) — no issues detected"
        }
        let layerName = rootResult.layer.rawValue
        switch rootResult.status {
        case .critical:
            return "Critical failure at \(layerName) layer (score \(healthScore)/100) — immediate action needed"
        case .degraded:
            return "Degradation detected at \(layerName) layer (score \(healthScore)/100) — service may be impacted"
        case .unknown:
            return "Insufficient data to pinpoint root cause (score \(healthScore)/100) — check device connectivity"
        case .healthy:
            return "All primary layers healthy (score \(healthScore)/100)"
        }
    }

    private static func makeRecommendations(rootCause: StackLayer,
                                            layers: [LayerResult],
                                            cm3000: ConnectorSnapshot?,
                                            firewalla: ConnectorSnapshot?) -> [String] {
        var recs: [String] = []

        // Modem-specific
        if let modemLayer = layers.first(where: { $0.layer == .modem }),
           modemLayer.status == .critical || modemLayer.status == .degraded {
            if cm3000?.metrics.first(where: { $0.key == "total_uncorr_codewords" })?.value ?? 0 > 0 {
                recs.append("Check coaxial splitters and connectors between wall outlet and CM3000")
                recs.append("Replace RG6 cable from wall outlet to CM3000 if uncorrectable errors persist")
                recs.append("Contact ISP to check signal levels at tap/node — upstream noise is common")
            }
            if cm3000?.metrics.first(where: { $0.key == "avg_us_power" })?.severity == .critical {
                recs.append("Upstream TX power too high — likely high-loss cable plant or bad splitter")
            }
        }

        // ISP-specific
        if rootCause == .isp {
            recs.append("Run a speed test from a device wired directly to the CM3000 (bypass Firewalla)")
            recs.append("Check Firewalla WAN interface status and ISP DHCP lease")
            recs.append("File an ISP support ticket with the CM3000 signal stats from the incident bundle")
        }

        // Firewall-specific
        if rootCause == .firewall {
            recs.append("Check Firewalla app for active security alerts that may be blocking traffic")
            recs.append("Review recent Firewalla rule changes")
        }

        // Mesh-specific
        if rootCause == .mesh || layers.first(where: { $0.layer == .mesh })?.status == .critical {
            recs.append("Reboot offline Orbi satellite nodes")
            recs.append("Check Orbi backhaul band (5 GHz or wired) for interference or weak signal")
        }

        // Generic
        if recs.isEmpty {
            if rootCause == .internet {
                recs.append("Issue is beyond your network equipment — check ISP status page")
                recs.append("Try alternative DNS resolvers (1.1.1.1, 8.8.8.8)")
            } else {
                recs.append("Review the per-connector snapshot files in the incident bundle for detail")
            }
        }

        return recs
    }

    // MARK: - Helpers

    private static func avgPingLoss(_ states: [PingState]) -> Double {
        guard !states.isEmpty else { return 0 }
        return states.reduce(0.0) { $0 + (1.0 - $1.successRate) } / Double(states.count)
    }

    private static func avgDNSFailure(_ states: [DNSState]) -> Double {
        guard !states.isEmpty else { return 0 }
        return states.reduce(0.0) { $0 + (1.0 - $1.successRate) } / Double(states.count)
    }

    private static func isPublicIP(_ host: String) -> Bool {
        !isPrivateIP(host) && !host.isEmpty
    }

    private static func isPrivateIP(_ host: String) -> Bool {
        host.hasPrefix("10.")   ||
        host.hasPrefix("192.168.") ||
        host.hasPrefix("172.16.") ||
        host.hasPrefix("172.17.") ||
        host.hasPrefix("172.18.") ||
        host.hasPrefix("172.19.") ||
        host.hasPrefix("172.2")  ||
        host.hasPrefix("172.3")  ||
        host == "localhost" || host == "127.0.0.1"
    }
}

// MARK: - LayerStatus ordering helper (for max(_:_:) comparisons)

private func max(_ a: LayerStatus, _ b: LayerStatus) -> LayerStatus {
    let order: [LayerStatus] = [.unknown, .healthy, .degraded, .critical]
    let ai = order.firstIndex(of: a) ?? 0
    let bi = order.firstIndex(of: b) ?? 0
    return ai >= bi ? a : b
}
