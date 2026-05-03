/// OrbiIntelligenceView.swift — Rich Netgear Orbi mesh panel
///
/// Tabs:
///   Overview  — Router summary tiles (WAN, clients, traffic) + satellite node list
///   Metrics   — Full ConnectorSnapshot metric grid with sparklines (mirrors ConnectorDetailView)
///   Events    — Connector event list
///   History   — ConnectorTimelineView trend chart
///
/// Accesses OrbiConnector by casting from ConnectorManager.

import SwiftUI

struct OrbiIntelligenceView: View {
    @EnvironmentObject var connectorManager: ConnectorManager

    private var orbi: OrbiConnector? {
        connectorManager.connectors.first(where: { $0.id == "orbi" }) as? OrbiConnector
    }

    private var snapshot: ConnectorSnapshot? {
        connectorManager.snapshot(for: "orbi")
    }

    @State private var tab: OrbiTab = .overview

    enum OrbiTab: String, CaseIterable {
        case overview = "Overview"
        case clients  = "Clients"
        case metrics  = "Metrics"
        case events   = "Events"
        case history  = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────────
            headerBar

            Divider()

            if snapshot != nil || orbi != nil {
                // Tab picker
                Picker("Tab", selection: $tab) {
                    ForEach(OrbiTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                Divider()

                // Tab content
                switch tab {
                case .overview: overviewTab
                case .clients:  clientsTab
                case .metrics:  metricsTab
                case .events:   eventsTab
                case .history:  ConnectorTimelineView(connectorId: "orbi")
                }
            } else {
                unavailableView
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.router.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Netgear Orbi")
                    .font(.headline)
                if let snap = snapshot {
                    Text(snap.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .help("Refresh Orbi now")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Overview tab

    @ViewBuilder
    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let orbi {
                    routerSummaryTiles(orbi.lastRouterSummary)
                    satelliteSection(orbi)
                    meshInterpretation(orbi)
                    meshGuidance(orbi)
                    ClaudeCompanionCard(
                        context: orbiClaudeContext(orbi),
                        promptHint: orbiClaudeHint(orbi)
                    )
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for Orbi data…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer(minLength: 40)
            }
            .padding(20)
        }
    }

    // MARK: - Clients tab

    @ViewBuilder
    private var clientsTab: some View {
        if let orbi, !orbi.lastClientsByAP.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    clientsNodeSection(
                        apMAC:    orbi.routerAPMAC,
                        nodeName: "Router",
                        nodeIcon: "wifi.router.fill",
                        clients:  orbi.lastClientsByAP[orbi.routerAPMAC] ?? [],
                        isRouter: true
                    )

                    ForEach(orbi.lastSatellites) { sat in
                        clientsNodeSection(
                            apMAC:    sat.mac,
                            nodeName: sat.name,
                            nodeIcon: "wifi",
                            clients:  orbi.lastClientsByAP[sat.mac] ?? [],
                            isRouter: false
                        )
                    }

                    // Any AP MACs not matched to router or known satellites
                    let knownMACs = Set(([orbi.routerAPMAC] + orbi.lastSatellites.map(\.mac))
                                         .map { $0.uppercased() })
                    let unknownAPs = orbi.lastClientsByAP.keys.filter {
                        !knownMACs.contains($0.uppercased())
                    }.sorted()
                    ForEach(unknownAPs, id: \.self) { apMAC in
                        let suffix = apMAC.components(separatedBy: ":").suffix(2).joined(separator: ":")
                        clientsNodeSection(
                            apMAC:    apMAC,
                            nodeName: "Node (\(suffix))",
                            nodeIcon: "wifi",
                            clients:  orbi.lastClientsByAP[apMAC] ?? [],
                            isRouter: false
                        )
                    }

                    Spacer(minLength: 40)
                }
                .padding(20)
            }
        } else if let orbi, orbi.lastClientsByAP.isEmpty && orbi.lastRouterSummary.totalClients > 0 {
            // Connected but client-by-AP data unavailable (single AP or no ConnAPMAC data)
            VStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("\(orbi.lastRouterSummary.totalClients) devices connected")
                    .font(.headline)
                Text("Per-node breakdown requires multiple AP nodes.\nAll clients appear to be on the same node.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for client data from Orbi…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func clientsNodeSection(
        apMAC: String, nodeName: String, nodeIcon: String,
        clients: [OrbiClientEntry], isRouter: Bool
    ) -> some View {
        GroupBox {
            if clients.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.slash")
                        .foregroundStyle(.secondary)
                    Text("No clients on this node")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            } else {
                VStack(spacing: 0) {
                    // Column header
                    HStack(spacing: 0) {
                        Text("").frame(width: 24)   // band icon
                        Text("Device").frame(maxWidth: .infinity, alignment: .leading)
                        Text("IP").frame(width: 110, alignment: .leading)
                        Text("MAC").frame(width: 130, alignment: .leading)
                        Text("Band").frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 4)

                    Divider()

                    ForEach(clients) { client in
                        OrbiClientRow(client: client)
                        if client.id != clients.last?.id {
                            Divider().padding(.horizontal, 8).opacity(0.5)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: nodeIcon)
                    .foregroundStyle(isRouter ? .blue : .purple)
                Text(nodeName)
                    .font(.subheadline.bold())
                if !apMAC.isEmpty {
                    Text(apMAC.lowercased())
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(clients.count) client\(clients.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Metrics tab

    @ViewBuilder
    private var metricsTab: some View {
        if let snap = snapshot, !snap.metrics.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible()), count: 3),
                        spacing: 10
                    ) {
                        ForEach(snap.metrics, id: \.key) { metric in
                            OrbiMetricCard(
                                metric: metric,
                                sparkline: connectorManager.snapshotStore
                                    .trend(for: "orbi", metricKey: metric.key, windowHours: 24)
                                    .sparkline
                            )
                        }
                    }
                    Spacer(minLength: 20)
                }
                .padding(20)
            }
        } else if snapshot != nil {
            Text("No metrics available")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Fetching metrics from Orbi…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Events tab

    @ViewBuilder
    private var eventsTab: some View {
        if let snap = snapshot, !snap.events.isEmpty {
            List {
                ForEach(Array(snap.events.prefix(30).enumerated()), id: \.offset) { _, event in
                    OrbiEventRow(event: event)
                }
            }
            .listStyle(.plain)
        } else {
            Text("No events recorded")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Router summary tiles

    private func routerSummaryTiles(_ s: OrbiRouterSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Router")
                    .font(.headline)
                if !s.firmware.isEmpty {
                    Text("FW \(s.firmware)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !s.firmwareUpdate.isEmpty {
                    Label("Update \(s.firmwareUpdate)", systemImage: "arrow.down.circle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: 4),
                spacing: 12
            ) {
                OrbiTile(
                    icon:  "network",
                    label: "WAN",
                    value: s.wanIP.isEmpty ? "–" : s.wanIP,
                    unit:  s.wanStatus,
                    color: s.wanConnected ? .green : .red
                )
                OrbiTile(
                    icon:  "laptopcomputer.and.iphone",
                    label: "Clients",
                    value: "\(s.totalClients)",
                    unit:  "connected",
                    color: .blue
                )
                OrbiTile(
                    icon:  "arrow.down.circle",
                    label: "Today RX",
                    value: s.todayRXmb.map { mbString($0) } ?? "–",
                    unit:  s.todayRXmb != nil ? "MB" : "",
                    color: .blue
                )
                OrbiTile(
                    icon:  "arrow.up.circle",
                    label: "Today TX",
                    value: s.todayTXmb.map { mbString($0) } ?? "–",
                    unit:  s.todayTXmb != nil ? "MB" : "",
                    color: .green
                )

                if let cpu = s.cpuPct {
                    OrbiTile(
                        icon:  "cpu",
                        label: "CPU",
                        value: String(format: "%.0f", cpu),
                        unit:  "%",
                        color: cpu > 90 ? .red : cpu > 70 ? .yellow : .green
                    )
                }
                if let mem = s.memPct {
                    OrbiTile(
                        icon:  "memorychip",
                        label: "Memory",
                        value: String(format: "%.0f", mem),
                        unit:  "%",
                        color: mem > 85 ? .red : mem > 70 ? .yellow : .green
                    )
                }
                if let weekRX = s.weekRXmb {
                    OrbiTile(
                        icon:  "calendar.circle",
                        label: "Week RX",
                        value: mbString(weekRX),
                        unit:  "MB",
                        color: .secondary
                    )
                }
                OrbiTile(
                    icon:  s.guestEnabled ? "person.2.wave.2.fill" : "person.2.slash",
                    label: "Guest",
                    value: s.guestEnabled ? "ON" : "OFF",
                    unit:  "",
                    color: s.guestEnabled ? .orange : Color(NSColor.secondaryLabelColor)
                )
            }
        }
    }

    private func mbString(_ mb: Double) -> String {
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        return String(format: "%.0f", mb)
    }

    // MARK: - Satellite section

    private func satelliteSection(_ orbi: OrbiConnector) -> some View {
        GroupBox {
            if orbi.lastSatellites.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("No satellite nodes detected")
                            .foregroundStyle(.secondary)
                        Text("Satellites appear here once they report in via GetAttachDevice2. If your Orbi has satellites that aren't showing up, try running a manual poll.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
            } else {
                VStack(spacing: 0) {
                    // Column headers
                    HStack(spacing: 0) {
                        Text("").frame(width: 10)
                        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("IP").frame(width: 120, alignment: .trailing)
                        Text("Backhaul").frame(width: 90, alignment: .trailing)
                        Text("Clients").frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)

                    Divider()

                    ForEach(orbi.lastSatellites) { sat in
                        SatelliteRow(satellite: sat)
                        Divider().padding(.horizontal, 8)
                    }
                }
            }
        } label: {
            HStack {
                Text("Satellite Nodes")
                Spacer()
                Text("\(orbi.lastSatellites.count) detected")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Mesh Interpretation (always shown on Overview)

    @ViewBuilder
    private func meshInterpretation(_ orbi: OrbiConnector) -> some View {
        let s           = orbi.lastRouterSummary
        let satellites  = orbi.lastSatellites
        let totalSats   = satellites.count
        let clientsByAP = orbi.lastClientsByAP

        VStack(alignment: .leading, spacing: 10) {
            Text("Mesh Interpretation")
                .font(.headline)

            // WAN card
            OrbiContextCard(
                color: s.wanConnected ? .green : .red,
                headline: s.wanConnected
                    ? "WAN Connected — \(s.wanIP.isEmpty ? "IP resolving…" : s.wanIP)"
                    : "WAN Offline",
                detail: s.wanConnected
                    ? "Your Orbi router has a live internet connection. The WAN IP shown is the address assigned by your cable modem. If this IP matches your CM3000's WAN IP, NAT is working correctly end-to-end."
                    : "The Orbi is reporting no WAN connectivity. Verify the ethernet cable between your CM3000 modem and the Orbi WAN port. Check the CM3000 connector — if the modem has a healthy DOCSIS lock, the problem is between the modem and Orbi."
            )

            // Satellite backhaul interpretation
            if !satellites.isEmpty {
                let wiredSats    = satellites.filter { $0.backhaulBand == "eth" || $0.backhaulBand == "wired" }
                let band6Sats    = satellites.filter { $0.backhaulBand == "6" }
                let band5Sats    = satellites.filter { $0.backhaulBand == "5" }
                let band24Sats   = satellites.filter { $0.backhaulBand == "2.4" || $0.backhaulBand == "2" }

                if !wiredSats.isEmpty {
                    OrbiContextCard(
                        color: .green,
                        headline: "\(wiredSats.count == totalSats ? "All" : "\(wiredSats.count)") Satellite\(wiredSats.count == 1 ? "" : "s") on Wired Backhaul — Ideal",
                        detail: "Ethernet backhaul eliminates wireless overhead between router and satellite entirely. Clients connected to these satellites get near-router performance regardless of physical distance or walls. This is the best possible Orbi configuration."
                    )
                }
                if !band6Sats.isEmpty {
                    OrbiContextCard(
                        color: .purple,
                        headline: "\(band6Sats.count) Satellite\(band6Sats.count == 1 ? "" : "s") on 6 GHz Backhaul — Excellent",
                        detail: "The 6 GHz tri-band backhaul is a dedicated wireless link between router and satellite — client traffic doesn't share this channel. Performance is near-wired. This is the best wireless backhaul option on Orbi 960 and 960-series hardware."
                    )
                }
                if !band5Sats.isEmpty {
                    OrbiContextCard(
                        color: .blue,
                        headline: "\(band5Sats.count) Satellite\(band5Sats.count == 1 ? "" : "s") on 5 GHz Backhaul — Good",
                        detail: "5 GHz backhaul is a dedicated wireless channel on tri-band Orbi models. Performance is good but may be affected by interference or distance. On dual-band models, 5 GHz is shared between backhaul and clients — throughput degrades as client count on that satellite increases. Watch for elevated latency when many clients are connected."
                    )
                }
                if !band24Sats.isEmpty {
                    OrbiContextCard(
                        color: .orange,
                        headline: "\(band24Sats.count) Satellite\(band24Sats.count == 1 ? "" : "s") on 2.4 GHz Backhaul — Suboptimal",
                        detail: "2.4 GHz backhaul is significantly slower and more latency-prone than 5 GHz or 6 GHz. Maximum throughput is ~300 Mbps theoretical (real-world typically 50–150 Mbps) with high contention on crowded channels. Devices connected to this satellite will experience higher latency. See the Guidance section for steps to improve backhaul quality."
                    )
                }
            }

            // Client distribution
            if !clientsByAP.isEmpty {
                let totalClients = clientsByAP.values.reduce(0) { $0 + $1.count }
                let routerClients = clientsByAP[orbi.routerAPMAC]?.count ?? 0
                let routerPct = totalClients > 0 ? Int(Double(routerClients) / Double(totalClients) * 100) : 0

                let (distColor, distHeadline, distDetail): (Color, String, String) = {
                    if totalClients == 0 { return (.secondary, "No Client Data", "Client distribution data will appear once devices connect and poll data is available.") }
                    if totalSats == 0    { return (.blue, "\(totalClients) Clients on Router", "All devices are connecting through the Orbi router. Add satellites if coverage is needed in distant rooms.") }
                    if routerPct > 70    { return (.yellow, "\(routerPct)% of Clients on Router Node", "\(routerClients) of \(totalClients) clients are on the router, leaving satellites underutilized. Devices far from the router may be connecting to it via weak 2.4 GHz signal instead of roaming to a closer satellite. This is a common \"sticky client\" problem — some devices won't roam until signal drops very low.") }
                    return (.green, "Clients Well-Distributed Across \(clientsByAP.count) Node\(clientsByAP.count == 1 ? "" : "s")", "Client load is spread across your mesh nodes. This maximises per-client throughput by avoiding congestion on any single AP.")
                }()
                OrbiContextCard(color: distColor, headline: distHeadline, detail: distDetail)
            }

            // CPU/Memory
            if let cpu = s.cpuPct {
                let (cpuColor, cpuHead, cpuDetail): (Color, String, String) = {
                    if cpu > 90 { return (.red, "CPU \(Int(cpu))% — Critical Load", "Router CPU is critically overloaded. This will cause latency spikes, packet drops, and may trigger connection resets. Common causes: high-rate NAT with many simultaneous connections, DPI/traffic analysis enabled, or a firmware bug. Reboot the router; if CPU stays high, disable bandwidth monitoring in the Orbi app.") }
                    if cpu > 70 { return (.yellow, "CPU \(Int(cpu))% — Elevated Load", "Router CPU is running hot. This is manageable for brief periods but sustained high CPU degrades routing performance. If it persists, reduce the number of active monitoring features or limit connected devices.") }
                    return (.green, "CPU \(Int(cpu))% — Normal", "Router CPU load is healthy. Plenty of headroom for current traffic levels and NAT workload.")
                }()
                OrbiContextCard(color: cpuColor, headline: cpuHead, detail: cpuDetail)
            }

            // Guest network
            if s.guestEnabled {
                OrbiContextCard(
                    color: .orange,
                    headline: "Guest Network Active",
                    detail: "The Orbi guest SSID is broadcasting. Guest clients are isolated from your primary LAN by default — they can reach the internet but cannot access your NAS, printers, or other local devices. Verify the guest network is intentionally active; leaving it on with a weak password is an attack surface."
                )
            }

            // Firmware update
            if !s.firmwareUpdate.isEmpty {
                OrbiContextCard(
                    color: .orange,
                    headline: "Firmware Update Available — \(s.firmwareUpdate)",
                    detail: "A new firmware version is available for your Orbi router. Netgear firmware updates typically include security patches, Wi-Fi stability fixes, and performance improvements. Update during a low-traffic period (the router will reboot). See the Guidance section for update steps."
                )
            }
        }
    }

    // MARK: - Mesh Guidance (shown when actionable issues present)

    @ViewBuilder
    private func meshGuidance(_ orbi: OrbiConnector) -> some View {
        let s           = orbi.lastRouterSummary
        let satellites  = orbi.lastSatellites
        let offlineSats = satellites.filter { !$0.isOnline }
        let band24Sats  = satellites.filter { $0.backhaulBand == "2.4" || $0.backhaulBand == "2" }
        let hasFirmware = !s.firmwareUpdate.isEmpty
        let cpuHigh     = (s.cpuPct ?? 0) > 70
        let hasIssue    = !offlineSats.isEmpty || !band24Sats.isEmpty || hasFirmware || cpuHigh || !s.wanConnected

        if hasIssue {
            VStack(alignment: .leading, spacing: 10) {
                Text("Guidance")
                    .font(.headline)

                if !s.wanConnected {
                    OrbiGuidanceCard(
                        icon: "network.slash",
                        color: .red,
                        title: "Restore WAN Connectivity",
                        steps: [
                            "Check the CM3000 modem's DS/US indicator LEDs — if blinking, the modem hasn't locked a DOCSIS channel and the issue is upstream.",
                            "Reseat the ethernet cable between modem and Orbi WAN port (usually the yellow port).",
                            "Power cycle in order: modem off → 2 min → on → wait for DOCSIS sync → power cycle Orbi.",
                            "If modem is synced but Orbi still shows no WAN, check whether the Orbi WAN port is set to DHCP (auto). A static IP mismatch will prevent connection.",
                            "If using PPPOE (some ISPs): verify your PPPOE credentials in Orbi admin → Advanced → Setup → Internet Setup."
                        ]
                    )
                }

                if !offlineSats.isEmpty {
                    OrbiGuidanceCard(
                        icon: "wifi.slash",
                        color: .red,
                        title: "\(offlineSats.count) Satellite\(offlineSats.count == 1 ? "" : "s") Offline",
                        steps: [
                            "Locate the offline satellite (\(offlineSats.map(\.name).joined(separator: ", "))) and check its power LED.",
                            "If the LED is white (syncing) or magenta/amber (error), power cycle: unplug → wait 30s → replug.",
                            "Move the satellite closer to the router temporarily to rule out range issues. If it syncs when close, it needs a relay node or to be relocated.",
                            "Ethernet backhaul: if the satellite connects via ethernet, check the cable and the switch/port it connects to.",
                            "If the satellite shows in the Orbi app as 'Disconnected' even when close to the router, do a factory reset on the satellite (pin hole reset) and re-add it."
                        ]
                    )
                }

                if !band24Sats.isEmpty {
                    OrbiGuidanceCard(
                        icon: "wifi.exclamationmark",
                        color: .orange,
                        title: "\(band24Sats.map(\.name).joined(separator: ", ")) — Poor Wireless Backhaul",
                        steps: [
                            "Move the satellite closer to the router. The 5 GHz backhaul band has shorter range than 2.4 GHz — getting the satellite within ~30 feet / one wall of the router is ideal.",
                            "Avoid placing satellites in closets, behind appliances, or near microwaves and cordless phones (2.4 GHz interference sources).",
                            "If the satellite is too far from the router to get 5 GHz backhaul, consider: (a) adding an intermediate satellite as a relay, or (b) running ethernet backhaul to the satellite location.",
                            "After moving, trigger a manual poll and check the backhaul band in the Clients tab — it should upgrade to 5 GHz or 6 GHz."
                        ]
                    )
                }

                if hasFirmware {
                    OrbiGuidanceCard(
                        icon: "arrow.down.circle.fill",
                        color: .orange,
                        title: "Firmware Update Available — \(s.firmwareUpdate)",
                        steps: [
                            "Open the Orbi admin panel (orbilogin.com or \(s.wanIP.isEmpty ? "your Orbi IP" : s.wanIP.components(separatedBy: ".").prefix(3).joined(separator: ".") + ".1")) → Advanced → Administration → Firmware Update.",
                            "Select 'Check' to confirm the update is available, then 'Update'.",
                            "Alternatively, use the Orbi mobile app → tap the router → Settings → Firmware.",
                            "The router will reboot after update (typically ~3 minutes). All connected devices will lose internet briefly."
                        ]
                    )
                }

                if cpuHigh {
                    OrbiGuidanceCard(
                        icon: "cpu",
                        color: .red,
                        title: "Router CPU High — Reduce Processing Load",
                        steps: [
                            "In the Orbi admin panel, disable traffic analysis / bandwidth monitoring if enabled — this is the most common cause of high CPU on consumer routers.",
                            "Disable QoS (Quality of Service) if you don't actively use it. QoS requires per-packet classification which is CPU-intensive.",
                            "Reduce the number of active VPN tunnels if any are idle.",
                            "Check if a firmware update is available — some CPU bugs are fixed in newer firmware.",
                            "If CPU stays above 90% after these steps, a reboot often clears a stuck process."
                        ]
                    )
                }
            }
        }
    }

    // MARK: - Claude companion context

    private func orbiClaudeContext(_ orbi: OrbiConnector) -> String {
        let s           = orbi.lastRouterSummary
        let satellites  = orbi.lastSatellites
        let totalClients = orbi.lastClientsByAP.values.reduce(0) { $0 + $1.count }
        let routerClients = orbi.lastClientsByAP[orbi.routerAPMAC]?.count ?? 0

        var lines = [
            "## Netgear Orbi Mesh Network",
            "WAN: \(s.wanConnected ? "CONNECTED (\(s.wanIP))" : "OFFLINE")",
            "Firmware: \(s.firmware.isEmpty ? "unknown" : s.firmware)\(s.firmwareUpdate.isEmpty ? "" : " → UPDATE \(s.firmwareUpdate) available")",
            "Total Clients: \(s.totalClients) (\(routerClients) on router\(satellites.isEmpty ? "" : ", \(totalClients - routerClients) on satellites"))",
            "Today Traffic: RX \(s.todayRXmb.map { String(format: "%.0f MB", $0) } ?? "–"), TX \(s.todayTXmb.map { String(format: "%.0f MB", $0) } ?? "–")",
            s.cpuPct != nil ? "CPU: \(String(format: "%.0f", s.cpuPct!))%" : "",
            s.memPct != nil ? "Memory: \(String(format: "%.0f", s.memPct!))%" : "",
            "Guest Network: \(s.guestEnabled ? "ACTIVE" : "Off")"
        ].filter { !$0.isEmpty }

        if !satellites.isEmpty {
            lines.append("")
            lines.append("Satellite Nodes (\(satellites.count)):")
            for sat in satellites {
                let clients = orbi.lastClientsByAP[sat.mac]?.count ?? 0
                lines.append("  \(sat.name): \(sat.isOnline ? "ONLINE" : "OFFLINE"), backhaul=\(sat.backhaulBand.isEmpty ? "unknown" : sat.backhaulBand)GHz, \(clients) clients")
            }
        }

        if let snap = snapshot, !snap.events.isEmpty {
            lines.append("")
            lines.append("Recent Events:")
            for ev in snap.events.prefix(5) {
                lines.append("  [\(ev.type)] \(ev.description)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func orbiClaudeHint(_ orbi: OrbiConnector) -> String {
        let satellites = orbi.lastSatellites
        let offlineSats = satellites.filter { !$0.isOnline }
        if !offlineSats.isEmpty {
            return "One of my Orbi satellite nodes is offline. What should I check to get it reconnected?"
        }
        let band24Sats = satellites.filter { $0.backhaulBand == "2.4" || $0.backhaulBand == "2" }
        if !band24Sats.isEmpty {
            return "My Orbi satellite is using 2.4 GHz backhaul. How can I improve this?"
        }
        let s = orbi.lastRouterSummary
        if !s.firmwareUpdate.isEmpty {
            return "Should I update my Orbi firmware to \(s.firmwareUpdate) and when is the best time to do it?"
        }
        let totalClients = orbi.lastClientsByAP.values.reduce(0) { $0 + $1.count }
        let routerClients = orbi.lastClientsByAP[orbi.routerAPMAC]?.count ?? 0
        if totalClients > 0 && !satellites.isEmpty {
            let routerPct = Int(Double(routerClients) / Double(totalClients) * 100)
            if routerPct > 70 {
                return "\(routerPct)% of my devices are on the router node. Are my satellites being underutilised?"
            }
        }
        return "How is my Orbi mesh network performing and are there any improvements I should make?"
    }

    // MARK: - Unavailable

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.router.fill")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Orbi connector not enabled")
            Text("Enable it in Preferences → Connectors.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Orbi Context Card (interpretation callout)

private struct OrbiContextCard: View {
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

// MARK: - Orbi Guidance Card (actionable steps)

private struct OrbiGuidanceCard: View {
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

// MARK: - Satellite Row

private struct SatelliteRow: View {
    let satellite: OrbiSatellite

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(satellite.isOnline ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(satellite.name).font(.callout)
                Text(satellite.mac)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(satellite.ip.isEmpty ? "–" : satellite.ip)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)

            HStack(spacing: 4) {
                Image(systemName: satellite.backhaulIcon)
                    .font(.caption)
                    .foregroundStyle(backhaulColor(satellite))
                Text(satellite.backhaulLabel)
                    .font(.caption)
                    .foregroundStyle(backhaulColor(satellite))
            }
            .frame(width: 90, alignment: .trailing)

            Text(satellite.clientCount == 0 ? "–" : "\(satellite.clientCount)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func backhaulColor(_ sat: OrbiSatellite) -> Color {
        switch sat.backhaulBand {
        case "6":   return .purple
        case "5":   return .blue
        case "eth", "wired": return .green
        default:    return .secondary
        }
    }
}

// MARK: - Metric Card

private struct OrbiMetricCard: View {
    let metric:    ConnectorMetric
    let sparkline: [Double]

    init(metric: ConnectorMetric, sparkline: [Double] = []) {
        self.metric    = metric
        self.sparkline = sparkline
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(displayValue)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(severityColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(metric.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if sparkline.count >= 3 && metric.value != 0 {
                MiniSparkline(values: sparkline)
                    .frame(height: 16)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(NSColor.controlBackgroundColor))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1))
    }

    private var displayValue: String {
        if metric.value == 0 && !metric.unit.isEmpty &&
           !["Mbps", "%", "MB", "h", "ms", "dB", "dBmV", "active", ""].contains(metric.unit) {
            return metric.unit
        }
        let v = metric.value
        switch metric.unit {
        case "h":     return String(format: "%.0fh", v)
        case "Mbps":  return String(format: "%.1f Mbps", v)
        case "%":     return String(format: "%.0f%%", v)
        case "MB":    return String(format: "%.0f MB", v)
        case "dB":    return String(format: "%.1f dB", v)
        case "dBmV":  return String(format: "%.1f dBmV", v)
        default:      return String(format: v < 10 && v != 0 ? "%.1f" : "%.0f", v)
        }
    }

    private var severityColor: Color {
        switch metric.severity {
        case .ok:       return .primary
        case .info:     return .blue
        case .warning:  return .yellow
        case .critical: return .red
        case .unknown:  return .secondary
        }
    }
}

// MARK: - Event Row

private struct OrbiEventRow: View {
    let event: ConnectorEvent

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(severityColor)
                .frame(width: 6, height: 6)
            Text(event.timestamp, style: .time)
                .font(.caption2).foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 60, alignment: .leading)
            Text(event.type.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(event.description)
                .font(.caption)
                .lineLimit(1)
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

// MARK: - Client Row

private struct OrbiClientRow: View {
    let client: OrbiClientEntry

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: client.bandIcon)
                .font(.caption)
                .foregroundStyle(bandColor)
                .frame(width: 24)

            Text(client.name)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(client.ip.isEmpty ? "–" : client.ip)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            Text(client.mac.isEmpty ? "–" : client.mac.lowercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 130, alignment: .leading)

            Text(client.bandLabel)
                .font(.caption2)
                .foregroundStyle(bandColor)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var bandColor: Color {
        let lc = client.connectionType.lowercased()
        if lc.contains("6")   { return .purple }
        if lc.contains("5")   { return .blue }
        if lc.contains("2.4") { return .green }
        if lc.contains("eth") { return .orange }
        return .secondary
    }
}

// MARK: - OrbiTile

private struct OrbiTile: View {
    let icon:  String
    let label: String
    let value: String
    let unit:  String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title2, design: .rounded).bold())
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        )
    }
}
