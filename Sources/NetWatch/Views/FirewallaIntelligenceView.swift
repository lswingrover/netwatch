/// FirewallaIntelligenceView.swift — Rich Firewalla data panel
///
/// Replaces the generic ConnectorDetailView for the Firewalla connector.
/// Surfaced from ConnectorsView when the selected connector id == "firewalla".
///
/// Tabs:
///   Overview  — WAN status, device counts, alarms, top domain, VPN, bandwidth summary
///   Devices   — full device list (online status, bandwidth, vendor, pause toggle)
///   Flows     — recent network flows (last 30 min, blocked highlighted)
///   Domains   — top DNS domains (last 24h)
///   Alarms    — Firewalla security alarms + events from snapshot

import SwiftUI

// MARK: - Root view

struct FirewallaIntelligenceView: View {

    @EnvironmentObject var connectorManager: ConnectorManager
    @EnvironmentObject var ifMonitor: InterfaceMonitor

    /// Convenience accessor — cast from the live connector list.
    private var firewalla: FirewallaConnector? {
        connectorManager.connectors.first(where: { $0.id == "firewalla" }) as? FirewallaConnector
    }

    private var snapshot: ConnectorSnapshot? {
        connectorManager.snapshot(for: "firewalla")
    }

    @State private var tab: FWTab = .overview
    @State private var deviceFilter: DeviceFilter = .all
    @State private var searchText: String = ""

    // Action feedback
    @State private var actionResult: ActionResult? = nil
    @State private var showActionBanner = false

    enum FWTab: String, CaseIterable {
        case overview = "Overview"
        case devices  = "Devices"
        case flows    = "Flows"
        case domains  = "Domains"
        case alarms   = "Alarms"
        case vpn      = "VPN"
    }

    enum DeviceFilter: String, CaseIterable {
        case all    = "All"
        case online = "Online"
        case paused = "Paused"
    }

    struct ActionResult {
        let success: Bool
        let message: String
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()

            if connectorManager.snapshot(for: "firewalla") != nil {
                // Tab picker
                Picker("Tab", selection: $tab) {
                    ForEach(FWTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                Divider()

                // Action result banner
                if showActionBanner, let result = actionResult {
                    actionBanner(result)
                }

                // Tab content
                switch tab {
                case .overview: overviewTab
                case .devices:  devicesTab
                case .flows:    flowsTab
                case .domains:  domainsTab
                case .alarms:   alarmsTab
                case .vpn:      vpnTab
                }
            } else {
                loadingOrEmpty
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Firewalla Gold")
                    .font(.headline)
                if let snap = snapshot {
                    Text(snap.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let error = connectorManager.connectorErrors["firewalla"] {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text("Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let snap = snapshot {
                Text(snap.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                connectorManager.pollNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Refresh Firewalla now")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Action banner

    private func actionBanner(_ result: ActionResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? .green : .red)
            Text(result.message)
                .font(.caption)
            Spacer()
            Button("Dismiss") { withAnimation { showActionBanner = false } }
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(result.success
            ? Color.green.opacity(0.1)
            : Color.red.opacity(0.1))
    }

    // MARK: - Loading / empty state

    private var loadingOrEmpty: some View {
        VStack(spacing: 12) {
            if let error = connectorManager.connectorErrors["firewalla"] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Firewalla connection failed")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                Button("Retry") { connectorManager.pollNow() }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            } else {
                ProgressView()
                Text("Waiting for Firewalla snapshot…")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Overview tab

    @ViewBuilder
    private var overviewTab: some View {
        if let snap = snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    networkStatusTiles(snap)
                    securitySummary(snap)
                    activitySummary(snap)
                    securityInterpretation(snap)
                    firewallGuidance(snap)
                    ClaudeCompanionCard(
                        context: firewallClaudeContext(snap),
                        promptHint: firewallClaudeHint(snap)
                    )
                    Spacer(minLength: 40)
                }
                .padding(20)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for Firewalla data…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func networkStatusTiles(_ snap: ConnectorSnapshot) -> some View {
        // Pull key metrics from snapshot
        let wanMetric   = snap.metrics.first(where: { $0.key.hasPrefix("wan_") && !$0.key.contains("ip") })
        let pubIP       = snap.metrics.first(where: { $0.key == "public_ip" })?.unit ?? "–"
        let totalDev    = Int(snap.metrics.first(where: { $0.key == "total_devices" })?.value ?? 0)
        let onlineDev   = Int(snap.metrics.first(where: { $0.key == "online_devices" })?.value ?? 0)
        let pausedDev   = Int(snap.metrics.first(where: { $0.key == "paused_devices" })?.value ?? 0)
        let alarmCount  = Int(snap.metrics.first(where: { $0.key == "active_alarms" })?.value ?? 0)
        let vpnTunnels  = Int(snap.metrics.first(where: { $0.key == "vpn_tunnels" })?.value ?? 0)
        let uptimeH      = snap.metrics.first(where: { $0.key == "uptime_h" })?.value
        let topDomain    = snap.metrics.first(where: { $0.key == "unique_domains" })?.unit ?? "–"
        let blockedTotal = Int(snap.metrics.first(where: { $0.key == "total_blocked" })?.value ?? 0)

        let wanActive = wanMetric?.severity == .ok
        let wanLabel  = wanMetric?.unit.isEmpty == false ? wanMetric!.unit : (wanActive ? "up" : "down")

        return VStack(alignment: .leading, spacing: 12) {
            Text("Network Status")
                .font(.headline)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: 4),
                spacing: 12
            ) {
                FWTile(icon: "network",
                       label: "WAN",
                       value: pubIP,
                       unit: wanLabel,
                       color: wanActive ? .green : .red)

                FWTile(icon: "laptopcomputer.and.iphone",
                       label: "Devices",
                       value: "\(onlineDev) / \(totalDev)",
                       unit: "online",
                       color: .blue)

                if pausedDev > 0 {
                    FWTile(icon: "pause.circle.fill",
                           label: "Paused",
                           value: "\(pausedDev)",
                           unit: "devices",
                           color: .orange)
                } else {
                    FWTile(icon: "checkmark.circle.fill",
                           label: "Paused",
                           value: "None",
                           unit: "",
                           color: .green)
                }

                FWTile(icon: alarmCount > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill",
                       label: "Alarms",
                       value: alarmCount > 0 ? "\(alarmCount)" : "None",
                       unit: alarmCount > 0 ? "active" : "",
                       color: alarmCount > 0 ? .orange : .green)

                FWTile(icon: "globe",
                       label: "Top Domain",
                       value: topDomain.isEmpty ? "–" : topDomain,
                       unit: "",
                       color: .blue)

                if blockedTotal > 0 {
                    FWTile(icon: "xmark.shield",
                           label: "Blocked",
                           value: blockedTotal >= 1000
                               ? String(format: "%.1fK", Double(blockedTotal) / 1000)
                               : "\(blockedTotal)",
                           unit: "requests",
                           color: .purple)
                }

                if vpnTunnels > 0 {
                    FWTile(icon: "lock.shield.fill",
                           label: "VPN",
                           value: "\(vpnTunnels)",
                           unit: vpnTunnels == 1 ? "tunnel" : "tunnels",
                           color: .green)
                }

                if let uptime = uptimeH {
                    let uptimeStr: String = {
                        if uptime >= 24 { return String(format: "%.0fd", uptime / 24) }
                        return String(format: "%.0fh", uptime)
                    }()
                    FWTile(icon: "clock.fill",
                           label: "Uptime",
                           value: uptimeStr,
                           unit: "",
                           color: .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func securitySummary(_ snap: ConnectorSnapshot) -> some View {
        let cyberAlarms = snap.events.filter { $0.type == "alarm" && $0.severity == .critical }
        let warnAlarms  = snap.events.filter { $0.type == "alarm" && $0.severity == .warning }
        let infoAlarms  = snap.events.filter { $0.type == "alarm" && $0.severity == .info }

        if !snap.events.filter({ $0.type == "alarm" }).isEmpty || !snap.events.filter({ $0.type == "blocked_flow" }).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Security")
                    .font(.headline)

                if cyberAlarms.isEmpty && warnAlarms.isEmpty && infoAlarms.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                        Text("No security alarms").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.06)))
                } else {
                    ForEach(Array((cyberAlarms + warnAlarms).prefix(3).enumerated()), id: \.offset) { _, ev in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle().fill(ev.severity == .critical ? Color.red : Color.orange)
                                .frame(width: 3).cornerRadius(2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ev.type.uppercased().replacingOccurrences(of: "_", with: " "))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(ev.description).font(.caption).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Text(ev.timestamp, style: .time)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill((ev.severity == .critical ? Color.red : Color.orange).opacity(0.06)))
                    }
                    if infoAlarms.count > 0 {
                        Text("\(infoAlarms.count) informational alarm(s) — view in Alarms tab")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func activitySummary(_ snap: ConnectorSnapshot) -> some View {
        let fw = firewalla
        let topFlows   = Array((fw?.lastFlows ?? []).prefix(5))
        let topDomains = Array((fw?.lastDomains ?? []).prefix(5))

        if !topFlows.isEmpty || !topDomains.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                // Recent flows mini-list
                if !topFlows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Flows").font(.headline)
                        ForEach(topFlows) { flow in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(flow.isBlocked ? Color.red : Color.blue)
                                    .frame(width: 5, height: 5)
                                Text(flow.domain.isEmpty ? flow.ip : flow.domain)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Text(flow.device.isEmpty ? flow.mac : flow.device)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Button("See all flows") { tab = .flows }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.blue).padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                }

                // Top domains mini-list
                if !topDomains.isEmpty {
                    let maxCount = Double(topDomains.first?.count ?? 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Domains").font(.headline)
                        ForEach(topDomains) { domain in
                            HStack(spacing: 6) {
                                let fraction = CGFloat(domain.count) / CGFloat(maxCount)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.blue.opacity(0.5))
                                    .frame(width: max(4, 60 * fraction), height: 6)
                                Text(domain.domain)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(domain.count)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Button("See all domains") { tab = .domains }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.blue).padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    // MARK: - Security Interpretation (always shown on Overview)

    @ViewBuilder
    private func securityInterpretation(_ snap: ConnectorSnapshot) -> some View {
        let blockedTotal = Int(snap.metrics.first(where: { $0.key == "total_blocked" })?.value ?? 0)
        let alarmCount   = Int(snap.metrics.first(where: { $0.key == "active_alarms" })?.value  ?? 0)
        let onlineDev    = Int(snap.metrics.first(where: { $0.key == "online_devices" })?.value ?? 0)
        let uptimeH      = snap.metrics.first(where: { $0.key == "uptime_h" })?.value
        let vpnTunnels   = Int(snap.metrics.first(where: { $0.key == "vpn_tunnels" })?.value ?? 0)
        let wanActive    = snap.metrics.first(where: { $0.key.hasPrefix("wan_") && !$0.key.contains("ip") })?.severity == .ok

        VStack(alignment: .leading, spacing: 10) {
            Text("Security Interpretation")
                .font(.headline)

            // WAN status card
            let uptimeStr: String = {
                guard let h = uptimeH else { return "uptime unknown" }
                if h >= 24 { return String(format: "%.0f days uptime", h / 24) }
                return String(format: "%.0f hours uptime", h)
            }()
            FWContextCard(
                color: wanActive ? .green : .red,
                headline: wanActive
                    ? "WAN Connected — \(uptimeStr)"
                    : "WAN Offline or Unavailable",
                detail: wanActive
                    ? "Your Firewalla's internet connection is active and healthy. The \(uptimeStr) figure reflects the Firewalla device uptime, not the WAN connection age specifically."
                    : "Firewalla is reporting no WAN connectivity. Check the coax/fiber line between your modem and router. If the CM3000 modem shows a healthy DOCSIS lock, the issue is between the modem and Firewalla WAN port."
            )

            // Alarm classification card
            let cyberAlarms = snap.events.filter { $0.type == "alarm" && $0.severity == .critical }
            let warnAlarms  = snap.events.filter { $0.type == "alarm" && $0.severity == .warning }
            let infoAlarms  = snap.events.filter { $0.type == "alarm" && $0.severity == .info }

            if alarmCount == 0 && cyberAlarms.isEmpty && warnAlarms.isEmpty {
                FWContextCard(
                    color: .green,
                    headline: "No Active Security Alarms",
                    detail: "Firewalla's threat detection engine is running and has not flagged any suspicious activity. This covers port scans, malware callbacks, abnormal data transfers, and geo-blocked connections. A clean alarm state is the normal operating condition for a well-configured home network."
                )
            } else if !cyberAlarms.isEmpty {
                FWContextCard(
                    color: .red,
                    headline: "\(cyberAlarms.count) Critical Alarm\(cyberAlarms.count == 1 ? "" : "s") — Requires Attention",
                    detail: "Critical alarms indicate activity Firewalla has high confidence is malicious or policy-violating: malware callbacks, port scans originating from inside your network, or active intrusion attempts. These are not false positives — they should be investigated promptly. See the Alarms tab for details and the Guidance section below for next steps."
                )
            } else if !warnAlarms.isEmpty {
                FWContextCard(
                    color: .orange,
                    headline: "\(warnAlarms.count) Warning Alarm\(warnAlarms.count == 1 ? "" : "s") — Review Recommended",
                    detail: "Warning alarms are Firewalla's medium-confidence flags: unusual outbound connections, new device activity, or geo-destination anomalies. Many are benign (new streaming service, VPN traffic, app update servers). Review the Alarms tab — most can be acknowledged or suppressed once you understand the source."
                )
            }
            if !infoAlarms.isEmpty {
                FWContextCard(
                    color: .blue,
                    headline: "\(infoAlarms.count) Informational Alarm\(infoAlarms.count == 1 ? "" : "s") — Low Priority",
                    detail: "Informational alarms are FYI-only: new device joined, geo-detection, or ad/tracker categories. They don't require action but are useful for auditing what's on your network. View them in the Alarms tab."
                )
            }

            // Blocked requests context
            if blockedTotal > 0 {
                let blockContext: (Color, String, String) = {
                    switch blockedTotal {
                    case ..<50:
                        return (.green,
                                "\(blockedTotal) Blocked Requests — Minimal Filtering Activity",
                                "A low block count typically means your network has few IoT devices or aggressive trackers. Firewalla is actively filtering but finding little to block. This is normal for a network with ad-blocking disabled or with devices that use HTTPS for everything.")
                    case 50..<500:
                        return (.blue,
                                "\(blockedTotal) Blocked Requests — Normal Filtering Activity",
                                "A moderate block count is typical for a home network with Firewalla's default rules active. This covers ad networks, tracking pixels, telemetry endpoints, and category-filtered domains. The Domains tab shows what's being blocked most frequently.")
                    case 500..<5000:
                        return (.yellow,
                                "\(blockedTotal >= 1000 ? String(format: "%.1fK", Double(blockedTotal)/1000) : "\(blockedTotal)") Blocked Requests — High Filtering Activity",
                                "A high block count suggests aggressive category filtering is active, a device is making many blocked requests (e.g. a smart TV hitting ad networks), or a rule is blocking legitimate traffic. Check the Domains tab for the top blocked domains and verify none are false positives causing app or service issues.")
                    default:
                        return (.orange,
                                "\(String(format: "%.1fK", Double(blockedTotal)/1000)) Blocked Requests — Very High — Investigate",
                                "An unusually high block count may indicate: (1) a device is being blocked on its primary communication channel causing retry loops, (2) a misconfigured rule blocking a CDN or update server, or (3) a device with aggressive ad-loading behavior. Open the Domains tab and sort by count to find the culprit domain.")
                    }
                }()
                FWContextCard(color: blockContext.0, headline: blockContext.1, detail: blockContext.2)
            }

            // VPN context
            if vpnTunnels > 0 {
                FWContextCard(
                    color: .green,
                    headline: "\(vpnTunnels) Active VPN Tunnel\(vpnTunnels == 1 ? "" : "s") — Remote Access Live",
                    detail: "WireGuard peers are actively connected to your Firewalla VPN server. Traffic from these peers traverses your home network under the same Firewalla rules as local devices. Check the VPN tab to see which peers are connected and their data transfer totals."
                )
            }

            // Devices context
            if onlineDev > 0 {
                let density: (Color, String) = {
                    switch onlineDev {
                    case ..<10:  return (.green, "Light network — \(onlineDev) online devices. Easy to monitor and identify any rogue device.")
                    case 10..<25: return (.blue, "\(onlineDev) online devices — typical busy home network. Use the Devices tab to identify any unfamiliar MAC addresses.")
                    default:     return (.yellow, "\(onlineDev) online devices — dense network. The Devices tab sorts by bandwidth; any device consuming disproportionate data warrants a look.")
                    }
                }()
                FWContextCard(color: density.0, headline: "Device Density", detail: density.1)
            }
        }
    }

    // MARK: - Firewall Guidance (shown when actionable issues present)

    @ViewBuilder
    private func firewallGuidance(_ snap: ConnectorSnapshot) -> some View {
        let cyberAlarms  = snap.events.filter { $0.type == "alarm" && $0.severity == .critical }
        let pausedDev    = Int(snap.metrics.first(where: { $0.key == "paused_devices" })?.value ?? 0)
        let blockedTotal = Int(snap.metrics.first(where: { $0.key == "total_blocked" })?.value ?? 0)
        let wanActive    = snap.metrics.first(where: { $0.key.hasPrefix("wan_") && !$0.key.contains("ip") })?.severity == .ok
        let hasIssue     = !cyberAlarms.isEmpty || pausedDev > 0 || !wanActive || blockedTotal > 5000

        if hasIssue {
            VStack(alignment: .leading, spacing: 10) {
                Text("Guidance")
                    .font(.headline)

                if !wanActive {
                    FWGuidanceCard(
                        icon: "network.slash",
                        color: .red,
                        title: "WAN Offline — Restore Internet Connectivity",
                        steps: [
                            "Check the CM3000 modem: if its DS/US indicator is blinking, the modem hasn't locked a DOCSIS channel. The issue is upstream of the Firewalla.",
                            "Verify the ethernet cable between modem and Firewalla WAN port. Reseat both ends.",
                            "Power cycle in order: modem off → wait 2 minutes → power on → wait for sync → power cycle Firewalla.",
                            "If the modem is online (solid DS/US lights) but Firewalla still shows no WAN, check Firewalla WAN settings (static vs. DHCP). The modem may not be releasing a DHCP lease after switching devices.",
                            "Contact Comcast if modem cannot acquire a DOCSIS lock (check CM3000 Events tab for T4 timeouts)."
                        ]
                    )
                }

                if !cyberAlarms.isEmpty {
                    FWGuidanceCard(
                        icon: "exclamationmark.shield.fill",
                        color: .red,
                        title: "Critical Security Alarm — Investigate Immediately",
                        steps: [
                            "Open the Alarms tab and read the alarm description carefully. Note the source device (IP and MAC) and the destination.",
                            "Identify the device: go to the Devices tab, find the MAC address, and confirm what device it is.",
                            "If the device is unknown or shouldn't be communicating externally, pause it immediately using the Pause button in the Devices tab.",
                            "For malware callback alarms: isolate the device (pause it), then run a malware scan (Windows: Malwarebytes; Mac: Malwarebytes or CleanMyMac; iOS/Android: factory reset is safest).",
                            "For port scan alarms: check whether it's originating from inside your network (compromised device) or is an inbound scan from the internet (less urgent — Firewalla blocks inbound by default).",
                            "After resolving, acknowledge the alarm in the Firewalla app to reset the alert state."
                        ]
                    )
                }

                if pausedDev > 0 {
                    FWGuidanceCard(
                        icon: "pause.circle.fill",
                        color: .orange,
                        title: "\(pausedDev) Device\(pausedDev == 1 ? "" : "s") Paused — Review Intentional Blocks",
                        steps: [
                            "Open the Devices tab and filter by Paused to see which devices have internet access blocked.",
                            "Verify each paused device is intentionally blocked (e.g. a child's device on schedule, a quarantined IoT device).",
                            "If a paused device is causing unexpected issues — a printer that can't update firmware, a hub that's lost cloud connectivity — consider unpausing and setting a traffic rule instead.",
                            "Pausing blocks all internet access for the device while allowing it to stay on the LAN (it can still reach local resources like a NAS)."
                        ]
                    )
                }

                if blockedTotal > 5000 {
                    FWGuidanceCard(
                        icon: "xmark.shield",
                        color: .orange,
                        title: "Very High Block Count — Check for False Positives",
                        steps: [
                            "Open the Domains tab and identify the top blocked domains.",
                            "Look for CDN domains (*.cloudfront.net, *.akamaihd.net), update servers, or app-specific APIs being blocked. These can silently break functionality.",
                            "In the Firewalla app, go to Rules → Blocked Domains and check for overly broad rules.",
                            "If a legitimate service is being blocked, whitelist the specific domain rather than disabling the entire category."
                        ]
                    )
                }
            }
        }
    }

    // MARK: - Claude companion context

    private func firewallClaudeContext(_ snap: ConnectorSnapshot) -> String {
        let wanMetric   = snap.metrics.first(where: { $0.key.hasPrefix("wan_") && !$0.key.contains("ip") })
        let pubIP       = snap.metrics.first(where: { $0.key == "public_ip" })?.unit ?? "–"
        let totalDev    = Int(snap.metrics.first(where: { $0.key == "total_devices" })?.value ?? 0)
        let onlineDev   = Int(snap.metrics.first(where: { $0.key == "online_devices" })?.value ?? 0)
        let pausedDev   = Int(snap.metrics.first(where: { $0.key == "paused_devices" })?.value ?? 0)
        let alarmCount  = Int(snap.metrics.first(where: { $0.key == "active_alarms" })?.value ?? 0)
        let vpnTunnels  = Int(snap.metrics.first(where: { $0.key == "vpn_tunnels" })?.value ?? 0)
        let uptimeH     = snap.metrics.first(where: { $0.key == "uptime_h" })?.value
        let blocked     = Int(snap.metrics.first(where: { $0.key == "total_blocked" })?.value ?? 0)
        let topBWName   = snap.metrics.first(where: { $0.key == "top_bw_name" })?.unit ?? "–"
        let topBWMB     = snap.metrics.first(where: { $0.key == "top_bw_device" })?.value
        let topDomain   = snap.metrics.first(where: { $0.key == "unique_domains" })?.unit ?? "–"

        let wanStatus = wanMetric?.severity == .ok ? "CONNECTED" : "OFFLINE"
        let uptimeStr = uptimeH.map { $0 >= 24 ? String(format: "%.0fd", $0/24) : String(format: "%.0fh", $0) } ?? "unknown"
        let alarms    = snap.events.filter { $0.type == "alarm" }
        let criticalAlarms = alarms.filter { $0.severity == .critical }

        var lines = [
            "## Firewalla Gold — Security Gateway",
            "WAN Status: \(wanStatus) (Public IP: \(pubIP))",
            "Uptime: \(uptimeStr)",
            "Devices: \(onlineDev) online / \(totalDev) total\(pausedDev > 0 ? " (\(pausedDev) paused)" : "")",
            "Active Alarms: \(alarmCount) (\(criticalAlarms.count) critical)",
            "Blocked Requests: \(blocked)",
            "VPN Tunnels Active: \(vpnTunnels)",
            "Top Bandwidth Device: \(topBWName)\(topBWMB != nil ? " (\(String(format: "%.0f", topBWMB!)) MB)" : "")",
            "Top DNS Domain: \(topDomain)"
        ]

        if !alarms.isEmpty {
            lines.append("")
            lines.append("Recent Alarms:")
            for alarm in alarms.prefix(5) {
                let sev = alarm.severity == .critical ? "CRITICAL" : alarm.severity == .warning ? "WARN" : "INFO"
                lines.append("  [\(sev)] \(alarm.description)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func firewallClaudeHint(_ snap: ConnectorSnapshot) -> String {
        let criticalAlarms = snap.events.filter { $0.type == "alarm" && $0.severity == .critical }
        if !criticalAlarms.isEmpty {
            return "I have \(criticalAlarms.count) critical security alarm(s). What are they and how serious is this?"
        }
        let blocked = Int(snap.metrics.first(where: { $0.key == "total_blocked" })?.value ?? 0)
        if blocked > 5000 {
            return "My Firewalla has blocked \(blocked) requests. Is this normal? Should I be concerned?"
        }
        let wanActive = snap.metrics.first(where: { $0.key.hasPrefix("wan_") && !$0.key.contains("ip") })?.severity == .ok
        if !wanActive {
            return "My Firewalla is showing no WAN connectivity. What should I check first?"
        }
        return "Summarise the security and network posture of my home network based on this Firewalla snapshot."
    }

    // MARK: - Devices tab

    @ViewBuilder
    private var devicesTab: some View {
        let fw = firewalla
        let devices = fw?.lastDevices ?? []

        VStack(spacing: 0) {
            // Filter + search bar
            HStack(spacing: 8) {
                Picker("Filter", selection: $deviceFilter) {
                    ForEach(DeviceFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Search devices…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .frame(width: 160)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if devices.isEmpty {
                Text("No device data yet. Waiting for poll…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let filtered = filteredDevices(devices)
                // Column header
                deviceColumnHeader
                Divider()
                List {
                    ForEach(filtered) { device in
                        DeviceRow(device: device, onAction: { action in
                            performFirewallaAction(action, fw: fw)
                        })
                    }
                }
                .listStyle(.plain)

                // Footer stats
                Divider()
                deviceFooter(devices)
            }
        }
    }

    private var deviceColumnHeader: some View {
        HStack(spacing: 0) {
            Text("Status")
                .frame(width: 52, alignment: .center)
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("IP")
                .frame(width: 110, alignment: .leading)
            Text("Vendor")
                .frame(width: 120, alignment: .leading)
            Text("Bandwidth")
                .frame(width: 80, alignment: .trailing)
            Text("Action")
                .frame(width: 70, alignment: .center)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func deviceFooter(_ all: [FirewallaDevice]) -> some View {
        let online  = all.filter { $0.isOnline  }.count
        let paused  = all.filter { $0.isPaused  }.count
        let total   = all.count
        return HStack(spacing: 16) {
            Label("\(total) total",  systemImage: "laptopcomputer.and.iphone").foregroundStyle(.secondary)
            Label("\(online) online", systemImage: "wifi").foregroundStyle(.green)
            if paused > 0 {
                Label("\(paused) paused", systemImage: "pause.circle").foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.caption2)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func filteredDevices(_ devices: [FirewallaDevice]) -> [FirewallaDevice] {
        var result = devices
        switch deviceFilter {
        case .all:    break
        case .online: result = result.filter { $0.isOnline }
        case .paused: result = result.filter { $0.isPaused }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q) ||
                $0.ip.contains(q) ||
                $0.mac.lowercased().contains(q) ||
                $0.vendor.lowercased().contains(q)
            }
        }
        return result
    }

    // MARK: - Flows tab

    @ViewBuilder
    private var flowsTab: some View {
        let flows = firewalla?.lastFlows ?? []
        if flows.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "waveform.path")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No recent flows (last 30 min)")
                    .foregroundStyle(.secondary)
                Text("Flow data requires flow:conn:in Redis key on the Firewalla.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                flowColumnHeader
                Divider()
                List {
                    ForEach(flows.prefix(100)) { flow in
                        FlowRow(flow: flow)
                    }
                }
                .listStyle(.plain)
                Divider()
                HStack {
                    let blocked = flows.filter { $0.isBlocked }.count
                    Text("\(flows.count) flows · \(blocked) blocked")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    private var flowColumnHeader: some View {
        HStack(spacing: 0) {
            Text("Time")
                .frame(width: 55, alignment: .leading)
            Text("Device")
                .frame(width: 120, alignment: .leading)
            Text("Domain / IP")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Cat")
                .frame(width: 80, alignment: .leading)
            Text("Bytes")
                .frame(width: 70, alignment: .trailing)
            Text("  ")
                .frame(width: 20)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Domains tab

    @ViewBuilder
    private var domainsTab: some View {
        let domains = firewalla?.lastDomains ?? []
        if domains.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No domain data yet")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let maxCount = Double(domains.first?.count ?? 1)
            List {
                ForEach(domains) { domain in
                    DomainRow(domain: domain, maxCount: maxCount)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Alarms tab

    @ViewBuilder
    private var alarmsTab: some View {
        let events = snapshot?.events ?? []
        let alarms = events.filter { $0.type == "alarm" }
        let other  = events.filter { $0.type != "alarm" }

        if events.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("No active alarms")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !alarms.isEmpty {
                    Section("Security Alarms (\(alarms.count))") {
                        ForEach(Array(alarms.enumerated()), id: \.offset) { _, event in
                            AlarmRow(event: event)
                        }
                    }
                }
                if !other.isEmpty {
                    Section("Network Events (\(other.count))") {
                        ForEach(Array(other.enumerated()), id: \.offset) { _, event in
                            AlarmRow(event: event)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - VPN tab

    @ViewBuilder
    private var vpnTab: some View {
        let fw          = firewalla
        let peers       = fw?.lastVPNPeers ?? []
        let homeIP      = fw?.homePublicIP ?? ""
        let macIP       = ifMonitor.publicIP
        let awayMode    = !macIP.isEmpty && !homeIP.isEmpty && macIP != homeIP
        let serverOn    = fw?.vpnServerEnabled ?? false
        let serverPort  = fw?.vpnServerPort ?? 51820
        let activeCount = fw?.vpnActiveCount ?? 0

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── Away / Home mode banner ───────────────────────────────────
                Group {
                    if macIP.isEmpty || homeIP.isEmpty {
                        vpnBanner(
                            icon: "questionmark.circle",
                            title: "Location unknown",
                            detail: macIP.isEmpty
                                ? "This Mac's public IP is still resolving…"
                                : "Firewalla public IP unavailable",
                            color: .secondary
                        )
                    } else if awayMode {
                        vpnBanner(
                            icon: "wifi.slash",
                            title: "Away Mode — off home network",
                            detail: "This Mac: \(macIP)  ·  Home WAN: \(homeIP)",
                            color: .orange
                        )
                    } else {
                        vpnBanner(
                            icon: "house.fill",
                            title: "Home Network",
                            detail: "This Mac and Firewalla share the same public IP: \(homeIP)",
                            color: .green
                        )
                    }
                }

                // ── WireGuard server status ───────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    Text("VPN Server")
                        .font(.headline)

                    HStack(spacing: 16) {
                        vpnStatusTile(
                            icon: serverOn ? "lock.shield.fill" : "lock.shield",
                            label: "WireGuard",
                            value: serverOn ? "Running" : "Not detected",
                            color: serverOn ? .green : .secondary
                        )
                        if serverOn {
                            vpnStatusTile(
                                icon: "antenna.radiowaves.left.and.right",
                                label: "Listen Port",
                                value: "UDP \(serverPort)",
                                color: .blue
                            )
                            vpnStatusTile(
                                icon: "person.2.fill",
                                label: "Peers",
                                value: "\(peers.count) configured",
                                color: .primary
                            )
                            vpnStatusTile(
                                icon: "checkmark.circle.fill",
                                label: "Active Now",
                                value: activeCount > 0 ? "\(activeCount) connected" : "None",
                                color: activeCount > 0 ? .green : .secondary
                            )
                        }
                    }

                    if !serverOn {
                        Text("WireGuard server not detected. NetWatch reads `wg show all dump` via SSH. The Firewalla pi user may need sudo access or the VPN server may not be configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // ── Peer list ─────────────────────────────────────────────────
                if serverOn && !peers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Peers")
                            .font(.headline)

                        // Column header
                        HStack(spacing: 0) {
                            Text("Status")  .frame(width: 56, alignment: .center)
                            Text("Key")     .frame(width: 80, alignment: .leading)
                            Text("Client IP").frame(width: 110, alignment: .leading)
                            Text("Endpoint").frame(maxWidth: .infinity, alignment: .leading)
                            Text("↓ Rx")   .frame(width: 75, alignment: .trailing)
                            Text("↑ Tx")   .frame(width: 75, alignment: .trailing)
                            Text("Handshake").frame(width: 90, alignment: .trailing)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.windowBackgroundColor))
                        .cornerRadius(6)

                        Divider()

                        ForEach(peers) { peer in
                            VPNPeerRow(peer: peer)
                            Divider().padding(.leading, 56)
                        }
                    }
                } else if serverOn && peers.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .foregroundStyle(.secondary)
                        Text("No peers configured yet. Add a WireGuard peer in the Firewalla app to enable remote access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
                }

                // ── VPN usage guide (always shown) ────────────────────────────
                if awayMode {
                    vpnConnectGuide(homeIP: homeIP, port: serverPort)
                }

                Spacer(minLength: 40)
            }
            .padding(20)
        }
    }

    private func vpnBanner(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(color == .secondary ? .primary : color)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color == .secondary
                      ? Color(NSColor.controlBackgroundColor)
                      : color.opacity(0.08))
        )
    }

    private func vpnStatusTile(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func vpnConnectGuide(homeIP: String, port: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("You're away — here's how to connect", systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.orange)
            Text("Open the WireGuard app and activate your home profile. Your Firewalla's WireGuard server is at \(homeIP.isEmpty ? "[home IP]" : homeIP):\(port). Once connected, NetWatch will continue working normally through the tunnel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !homeIP.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(homeIP, forType: .string)
                } label: {
                    Label("Copy home IP", systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Action dispatch

    private func performFirewallaAction(_ action: FirewallaAction, fw: FirewallaConnector?) {
        guard let fw else { return }
        Task {
            do {
                let msg = try await fw.performAction(action)
                await MainActor.run {
                    actionResult   = ActionResult(success: true, message: msg)
                    showActionBanner = true
                }
                // Re-poll after a short delay so UI reflects the change
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                connectorManager.pollNow()
            } catch {
                await MainActor.run {
                    actionResult   = ActionResult(success: false, message: error.localizedDescription)
                    showActionBanner = true
                }
            }
        }
    }
}

// MARK: - FW Tile (Overview tab building block)

private struct FWTile: View {
    let icon:  String
    let label: String
    let value: String
    let unit:  String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device: FirewallaDevice
    let onAction: (FirewallaAction) -> Void

    @State private var isActing = false

    var body: some View {
        HStack(spacing: 0) {
            // Online status dot + paused indicator
            ZStack {
                Circle()
                    .fill(device.isOnline ? Color.green : Color(NSColor.tertiaryLabelColor))
                    .frame(width: 7, height: 7)
                if device.isPaused {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .offset(x: 6, y: -5)
                }
            }
            .frame(width: 52, alignment: .center)

            // Name
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)
                Text(device.mac)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // IP
            Text(device.ip.isEmpty ? "–" : device.ip)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            // Vendor
            Text(device.vendor.isEmpty ? "–" : device.vendor)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            // Bandwidth
            Text(device.totalBandwidthFormatted)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(device.totalBytes > 1_073_741_824 ? .orange : .primary)
                .frame(width: 80, alignment: .trailing)

            // Action button
            Group {
                if isActing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 70, height: 20)
                } else {
                    Button(device.isPaused ? "Resume" : "Pause") {
                        isActing = true
                        let action: FirewallaAction = device.isPaused
                            ? .resume(mac: device.mac)
                            : .pause(mac: device.mac)
                        onAction(action)
                        // Re-enable button after 5s (connector re-poll will update state)
                        Task {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            await MainActor.run { isActing = false }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .foregroundStyle(device.isPaused ? .green : .orange)
                    .frame(width: 70, alignment: .center)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(device.isPaused ? Color.orange.opacity(0.06) : Color.clear)
        .contextMenu {
            if !device.ip.isEmpty {
                Button("Copy IP") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(device.ip, forType: .string) }
            }
            Button("Copy MAC") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(device.mac, forType: .string) }
            Divider()
            Button(device.isPaused ? "Resume Device" : "Pause Device") {
                let action: FirewallaAction = device.isPaused
                    ? .resume(mac: device.mac)
                    : .pause(mac: device.mac)
                onAction(action)
            }
        }
    }
}

// MARK: - Flow Row

private struct FlowRow: View {
    let flow: FirewallaFlow

    var body: some View {
        HStack(spacing: 0) {
            Text(flow.timestamp, style: .time)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .leading)

            Text(flow.device.isEmpty ? flow.mac : flow.device)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(flow.domain.isEmpty ? flow.ip : flow.domain)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(flow.isBlocked ? .red : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(flow.category.isEmpty ? "–" : flow.category)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)

            Text(FirewallaDevice.formatBytes(flow.bytes))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)

            if flow.isBlocked {
                Image(systemName: "xmark.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(width: 20)
            } else {
                Spacer().frame(width: 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(flow.isBlocked ? Color.red.opacity(0.04) : Color.clear)
        .contextMenu {
            if !flow.domain.isEmpty {
                Button("Copy Domain") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(flow.domain, forType: .string) }
            }
            if !flow.ip.isEmpty {
                Button("Copy IP") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(flow.ip, forType: .string) }
            }
        }
    }
}

// MARK: - Domain Row

private struct DomainRow: View {
    let domain: FirewallaDomain
    let maxCount: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(domain.domain)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Bar
            GeometryReader { geo in
                let fraction = CGFloat(domain.count) / CGFloat(maxCount)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(0.6))
                        .frame(width: geo.size.width * fraction, height: 6)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: 120, height: 16)

            Text("\(domain.count)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Domain") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(domain.domain, forType: .string)
            }
        }
    }
}

// MARK: - VPN Peer Row

private struct VPNPeerRow: View {
    let peer: FirewallaVPNPeer

    var body: some View {
        HStack(spacing: 0) {
            // Active / inactive indicator
            ZStack {
                Circle()
                    .fill(peer.isActive ? Color.green : Color(NSColor.tertiaryLabelColor))
                    .frame(width: 7, height: 7)
                if peer.isActive {
                    Circle()
                        .fill(Color.green.opacity(0.25))
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 56, alignment: .center)

            // Pubkey short
            Text(peer.pubkeyShort.isEmpty ? "–" : peer.pubkeyShort + "…")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(peer.isActive ? .primary : .secondary)
                .frame(width: 80, alignment: .leading)

            // Allowed IPs (client-side tunnel IP)
            Text(peer.allowedIPs.isEmpty ? "–" : peer.allowedIPs)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            // Endpoint IP (last seen public IP)
            Text(peer.endpoint.isEmpty ? "–" : peer.endpoint)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Rx bytes
            Text(FirewallaDevice.formatBytes(peer.rxBytes))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 75, alignment: .trailing)

            // Tx bytes
            Text(FirewallaDevice.formatBytes(peer.txBytes))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 75, alignment: .trailing)

            // Last handshake
            Text(peer.lastHandshakeFormatted)
                .font(.caption2)
                .foregroundStyle(peer.isActive ? .green : .secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(peer.isActive ? Color.green.opacity(0.04) : Color.clear)
        .contextMenu {
            if !peer.allowedIPs.isEmpty {
                Button("Copy Tunnel IP") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(peer.allowedIPs, forType: .string)
                }
            }
            if !peer.endpoint.isEmpty {
                Button("Copy Endpoint") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(peer.endpoint, forType: .string)
                }
            }
            if !peer.pubkeyShort.isEmpty {
                Button("Copy Public Key (short)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(peer.pubkeyShort, forType: .string)
                }
            }
        }
    }
}

// MARK: - FW Context Card (interpretation callout)

private struct FWContextCard: View {
    let color:    Color
    let headline: String
    let detail:   String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
                .cornerRadius(2)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.06)))
    }
}

// MARK: - FW Guidance Card (actionable steps)

private struct FWGuidanceCard: View {
    let icon:  String
    let color: Color
    let title: String
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).")
                            .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(step)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.2), lineWidth: 1))
        )
    }
}

// MARK: - Alarm Row

private struct AlarmRow: View {
    let event: ConnectorEvent

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(severityColor)
                .frame(width: 7, height: 7)
            Text(event.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 55, alignment: .leading)
            Text(event.type.uppercased().replacingOccurrences(of: "_", with: " "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(event.description)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var severityColor: Color {
        switch event.severity {
        case .ok, .info: return .blue
        case .warning:   return .yellow
        case .critical:  return .red
        case .unknown:   return .secondary
        }
    }
}
