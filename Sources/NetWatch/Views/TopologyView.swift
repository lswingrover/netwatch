/// TopologyView.swift — Live network topology diagram
///
/// Renders a node-link diagram of the monitored network stack:
///
///   [Internet] ── [ISP PoP] ── [ISP CMTS] ── [CM3000] ── [Firewalla] ── [Orbi]
///                                                                              │
///                                                              [Satellite 1]  [Satellite 2]
///                                                                     [This Mac]
///
/// ISP hop nodes are derived from the live traceroute results — the first public
/// (non-RFC-1918) hops beyond the local stack.
///
/// "This Mac" appears as a leaf node connected to the Orbi, showing the local IP
/// and the count of TCP/UDP listening ports.
///
/// Clicking a node navigates to its detail view in ConnectorsView (via callback).

import SwiftUI

// MARK: - Topology node model

struct TopologyNode: Identifiable {
    let id:       String
    let label:    String
    let sublabel: String     // secondary info shown under the label
    let icon:     String     // SF Symbol name
    let status:   TopologyStatus
    var position: CGPoint = .zero   // set during layout
}

enum TopologyStatus {
    case healthy, degraded, critical, unknown, offline

    var color: Color {
        switch self {
        case .healthy:  return .green
        case .degraded: return .yellow
        case .critical: return .red
        case .unknown:  return Color(NSColor.secondaryLabelColor)
        case .offline:  return Color(NSColor.tertiaryLabelColor)
        }
    }
    var fillColor: Color { color.opacity(0.12) }
}

struct TopologyEdge {
    let from: String    // node id
    let to:   String    // node id
    var isDashed: Bool = false
}

// MARK: - View

struct TopologyView: View {
    @EnvironmentObject var monitor:          NetworkMonitorService
    @EnvironmentObject var connectorManager: ConnectorManager
    @EnvironmentObject var ifMonitor:        InterfaceMonitor

    /// Called when a node is tapped. Passes the connector ID (or special ID for synthetic nodes).
    var onNodeTapped: ((String) -> Void)? = nil

    @State private var hoveredID:    String? = nil
    @State private var openPortCount: Int    = 0

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            topologyCanvas
                .padding(40)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            // Count listening ports via lsof
            let output = await ProcessRunner.runPermissive(
                "/usr/sbin/lsof", args: ["-i", "-P", "-n"], timeout: 5)
            let count = output.components(separatedBy: "\n")
                .filter { $0.contains("LISTEN") }.count
            openPortCount = count
        }
    }

    // MARK: - Canvas

    private var topologyCanvas: some View {
        let (nodes, edges) = buildGraph()

        // Compute needed canvas size from node positions
        let maxX = (nodes.map(\.position.x).max() ?? 400) + nodeW / 2 + 20
        let maxY = (nodes.map(\.position.y).max() ?? 400) + nodeH / 2 + 20

        return ZStack {
            // Draw edges first (behind nodes)
            Canvas { ctx, _ in
                for edge in edges {
                    guard let from = nodes.first(where: { $0.id == edge.from }),
                          let to   = nodes.first(where: { $0.id == edge.to   }) else { continue }
                    drawEdge(ctx: &ctx, from: from.position, to: to.position,
                             color: edgeColor(fromNode: from, toNode: to),
                             dashed: edge.isDashed)
                }
            }

            // Draw nodes on top
            ForEach(nodes) { node in
                NodeView(node: node, isHovered: hoveredID == node.id)
                    .position(node.position)
                    .onHover { hoveredID = $0 ? node.id : nil }
                    .onTapGesture {
                        handleTap(node: node)
                    }
                    .help(helpText(for: node))
            }
        }
        .frame(width: maxX, height: maxY)
    }

    private func handleTap(node: TopologyNode) {
        guard let cb = onNodeTapped else { return }
        // Only navigable nodes: known connector IDs or satellite IDs
        switch node.id {
        case "internet", "isp_hop_0", "isp_hop_1", "this_mac":
            return  // informational only
        default:
            cb(node.id)
        }
    }

    private func helpText(for node: TopologyNode) -> String {
        switch node.id {
        case "internet":  return "Internet connectivity (ping-derived)"
        case "isp_hop_0", "isp_hop_1": return "ISP intermediate node (traceroute-derived)"
        case "this_mac":  return "This Mac — \(ifMonitor.ipAddress)"
        default:          return "Tap to open \(node.label) in Devices"
        }
    }

    // MARK: - Edge drawing

    private func drawEdge(ctx: inout GraphicsContext, from: CGPoint, to: CGPoint,
                          color: Color, dashed: Bool = false) {
        var path = Path()
        path.move(to: from)
        let mid   = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let ctrl1 = CGPoint(x: mid.x, y: from.y)
        let ctrl2 = CGPoint(x: mid.x, y: to.y)
        path.addCurve(to: to, control1: ctrl1, control2: ctrl2)
        let style: StrokeStyle = dashed
            ? StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 4])
            : StrokeStyle(lineWidth: 2,   lineCap: .round)
        ctx.stroke(path, with: .color(color.opacity(0.5)), style: style)
    }

    private func edgeColor(fromNode: TopologyNode, toNode: TopologyNode) -> Color {
        let worst = [fromNode.status, toNode.status].contains(.critical) ? TopologyStatus.critical
                  : [fromNode.status, toNode.status].contains(.degraded) ? .degraded
                  : .healthy
        return worst.color
    }

    // MARK: - Graph builder

    private func buildGraph() -> (nodes: [TopologyNode], edges: [TopologyEdge]) {
        var nodes: [TopologyNode] = []
        var edges: [TopologyEdge] = []

        var row = 0

        // ── Internet ─────────────────────────────────────────────────────────
        let internetStatus = pingStatus(hosts: ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
        var internetNode = TopologyNode(
            id: "internet", label: "Internet", sublabel: "",
            icon: "globe", status: internetStatus)
        internetNode.position = colCenter(row: row, col: 0, ofCols: 1)
        nodes.append(internetNode)
        row += 1

        // ── ISP hop nodes from traceroute ─────────────────────────────────────
        let ispHops = extractISPHops()
        var lastNodeID = "internet"
        for (i, hop) in ispHops.enumerated() {
            let hopID    = "isp_hop_\(i)"
            let hopLabel = i == 0 ? "ISP CMTS" : "ISP PoP"
            let rttStr   = hop.avgRTT.map { String(format: "%.1f ms", $0) } ?? "* * *"
            let sublabel = "\(hop.ip ?? "–") · \(rttStr)"
            var hopNode  = TopologyNode(
                id: hopID, label: hopLabel, sublabel: sublabel,
                icon: "antenna.radiowaves.left.and.right", status: .unknown)
            hopNode.position = colCenter(row: row, col: 0, ofCols: 1)
            nodes.append(hopNode)
            edges.append(TopologyEdge(from: lastNodeID, to: hopID, isDashed: true))
            lastNodeID = hopID
            row += 1
        }

        // ── CM3000 ────────────────────────────────────────────────────────────
        let cm3000Status = connectorStatus(id: "cm3000")
        let cm3000Snap   = connectorManager.snapshot(for: "cm3000")
        let cm3000Sub    = cm3000Snap?.metrics.first(where: { $0.key.contains("snr") || $0.key == "ds_snr_avg" })
                                      .map { String(format: "SNR %.1f dB", $0.value) } ?? ""
        var cm3000Node = TopologyNode(
            id: "cm3000", label: "CM3000", sublabel: cm3000Sub,
            icon: "cable.connector.horizontal", status: cm3000Status)
        cm3000Node.position = colCenter(row: row, col: 0, ofCols: 1)
        nodes.append(cm3000Node)
        edges.append(TopologyEdge(from: lastNodeID, to: "cm3000"))
        row += 1

        // ── Firewalla ─────────────────────────────────────────────────────────
        let fwStatus = connectorStatus(id: "firewalla")
        let fwSnap   = connectorManager.snapshot(for: "firewalla")
        let fwSub    = fwSnap?.metrics.first(where: { $0.key == "device_count" })
                               .map { "\(Int($0.value)) devices" } ?? ""
        var fwNode = TopologyNode(
            id: "firewalla", label: "Firewalla", sublabel: fwSub,
            icon: "shield.lefthalf.filled", status: fwStatus)
        fwNode.position = colCenter(row: row, col: 0, ofCols: 1)
        nodes.append(fwNode)
        edges.append(TopologyEdge(from: "cm3000", to: "firewalla"))
        row += 1

        // ── Orbi Router ───────────────────────────────────────────────────────
        let orbi       = connectorManager.connectors.first(where: { $0.id == "orbi" }) as? OrbiConnector
        let orbiStatus = connectorStatus(id: "orbi")
        let orbiSummary = orbi?.lastRouterSummary
        let orbiSub    = orbiSummary.map { "WAN \($0.wanIP.isEmpty ? "–" : $0.wanIP)" } ?? ""
        var orbiNode = TopologyNode(
            id: "orbi", label: "Orbi", sublabel: orbiSub,
            icon: "wifi.router.fill", status: orbiStatus)
        orbiNode.position = colCenter(row: row, col: 0, ofCols: 1)
        nodes.append(orbiNode)
        edges.append(TopologyEdge(from: "firewalla", to: "orbi"))
        row += 1

        // ── Leaf row: Satellites + This Mac ──────────────────────────────────
        let satellites = orbi?.lastSatellites ?? []
        let totalLeaves = satellites.count + 1  // +1 for This Mac
        let leafRow = row

        for (i, sat) in satellites.enumerated() {
            let satID = "sat_\(sat.mac)"
            var satNode = TopologyNode(
                id: satID,
                label: sat.name,
                sublabel: "\(sat.backhaulLabel) · \(sat.clientCount) clients",
                icon: "wifi",
                status: sat.isOnline ? .healthy : .offline)
            satNode.position = colCenter(row: leafRow, col: i, ofCols: totalLeaves)
            nodes.append(satNode)
            edges.append(TopologyEdge(from: "orbi", to: satID))
        }

        // This Mac node
        let macSublabel: String
        if !ifMonitor.ipAddress.isEmpty {
            macSublabel = openPortCount > 0
                ? "\(ifMonitor.ipAddress) · \(openPortCount) ports"
                : ifMonitor.ipAddress
        } else {
            macSublabel = openPortCount > 0 ? "\(openPortCount) ports" : ""
        }
        var macNode = TopologyNode(
            id: "this_mac", label: "This Mac", sublabel: macSublabel,
            icon: "laptopcomputer", status: .healthy)
        macNode.position = colCenter(row: leafRow, col: satellites.count, ofCols: totalLeaves)
        nodes.append(macNode)
        edges.append(TopologyEdge(from: "orbi", to: "this_mac", isDashed: true))

        return (nodes, edges)
    }

    // MARK: - ISP Hop extraction

    private func extractISPHops() -> [TracerouteHop] {
        // Prefer the result for the first traceroute target
        guard let result = monitor.tracerouteMonitor.results.values.first else { return [] }
        let publicHops = result.hops.filter { hop in
            guard let ip = hop.ip else { return false }
            return !isPrivateOrSpecial(ip) && !hop.isTimeout
        }
        // Show up to 2 ISP hops (CMTS + first PoP)
        return Array(publicHops.prefix(2))
    }

    private func isPrivateOrSpecial(_ ip: String) -> Bool {
        ip.hasPrefix("10.")          ||
        ip.hasPrefix("192.168.")     ||
        ip.hasPrefix("172.16.")      ||
        ip.hasPrefix("172.17.")      ||
        ip.hasPrefix("172.18.")      ||
        ip.hasPrefix("172.19.")      ||
        ip.hasPrefix("172.2")        ||
        ip.hasPrefix("172.3")        ||
        ip.hasPrefix("127.")         ||
        ip.hasPrefix("169.254.")     ||
        ip == "0.0.0.0"              ||
        ip == "*"
    }

    // MARK: - Layout

    private let nodeW: CGFloat = 130
    private let nodeH: CGFloat = 70
    private let rowH:  CGFloat = 130
    private let colW:  CGFloat = 160

    /// Returns the centred x position for col `col` of `ofCols` columns, at row `row`.
    private func colCenter(row: Int, col: Int, ofCols: Int) -> CGPoint {
        let totalW = max(CGFloat(ofCols) * colW, colW)
        let startX = (max(totalW, colW) - CGFloat(ofCols) * colW) / 2 + colW / 2
        let x = startX + CGFloat(col) * colW
        let y = CGFloat(row) * rowH + rowH / 2
        return CGPoint(x: x, y: y)
    }

    // MARK: - Status helpers

    private func pingStatus(hosts: [String]) -> TopologyStatus {
        let relevant = monitor.pingStates.filter { hosts.contains($0.target.host) }
        guard !relevant.isEmpty else { return .unknown }
        let failing = relevant.filter { !$0.isOnline }
        if failing.count == relevant.count { return .critical }
        if failing.count > 0              { return .degraded  }
        return .healthy
    }

    private func connectorStatus(id: String) -> TopologyStatus {
        guard let snap = connectorManager.snapshot(for: id) else { return .unknown }
        let criticalCount = snap.events.filter { $0.severity == .critical }.count
        let warnCount     = snap.events.filter { $0.severity == .warning  }.count
        if criticalCount > 0 { return .critical }
        if warnCount > 0     { return .degraded  }
        return .healthy
    }
}

// MARK: - Node View

private struct NodeView: View {
    let node:      TopologyNode
    let isHovered: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(node.status.fillColor)
                    .frame(width: 46, height: 46)
                Circle()
                    .strokeBorder(node.status.color,
                                  lineWidth: isHovered ? 2.5 : 1.5)
                    .frame(width: 46, height: 46)
                Image(systemName: node.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(node.status.color)
            }
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)

            Text(node.label)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if !node.sublabel.isEmpty {
                Text(node.sublabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: 110)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06),
                        radius: isHovered ? 6 : 3, y: 2)
        )
    }
}
