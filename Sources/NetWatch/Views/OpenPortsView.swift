/// OpenPortsView.swift — Listening ports on this Mac
///
/// Runs `lsof -nP -iTCP -sTCP:LISTEN` to enumerate all TCP listening sockets,
/// then groups and presents them with process name, PID, address, and a brief
/// description of well-known ports so the user understands what each service is.
///
/// Security note: High-numbered ports bound to 0.0.0.0 (all interfaces) are
/// flagged in orange; well-known services on loopback-only are shown in blue.
/// This is informational — not a vulnerability scanner.

import SwiftUI
import Foundation

// MARK: - Data model

struct ListeningPort: Identifiable {
    var id: String { "\(pid)-\(address)-\(port)" }

    let process:   String    ///< Process display name (from lsof COMMAND)
    let pid:       Int
    let proto:     String    ///< "TCP" or "UDP"
    let address:   String    ///< Bound address ("*", "127.0.0.1", "::", etc.)
    let port:      Int
    let isLoopback: Bool     ///< true if bound to 127.x or ::1 only
    let isWildcard: Bool     ///< true if bound to * / 0.0.0.0 / ::

    /// One-line description of the service, if well-known.
    var serviceHint: String {
        switch port {
        case 22:    return "SSH"
        case 80:    return "HTTP"
        case 443:   return "HTTPS"
        case 631:   return "CUPS (printing)"
        case 3000:  return "Common dev server"
        case 3306:  return "MySQL"
        case 4000:  return "Common dev server"
        case 5000:  return "Common dev server / AirPlay receiver"
        case 5432:  return "PostgreSQL"
        case 6379:  return "Redis"
        case 6000...6999: return "X11"
        case 7000:  return "AirPlay / Rapport"
        case 7100:  return "Font Service"
        case 8080:  return "HTTP alt / dev server"
        case 8443:  return "HTTPS alt"
        case 8888:  return "Jupyter / dev server"
        case 9000:  return "Common dev server"
        case 27017: return "MongoDB"
        case 49152...65535: return "Ephemeral / dynamic"
        default:    return ""
        }
    }

    /// Security posture of this port.
    var exposure: PortExposure {
        if isLoopback  { return .loopback }
        if isWildcard  { return .exposed }   // wildcard beats well-known: port 80 on 0.0.0.0 is exposed
        if port < 1024 { return .wellKnown }
        return .bound
    }
}

enum PortExposure: String {
    case loopback  = "Loopback only"
    case wellKnown = "Well-known port"
    case exposed   = "All interfaces"
    case bound     = "Specific interface"
}

// MARK: - View

struct OpenPortsView: View {

    @State private var ports:       [ListeningPort] = []
    @State private var isLoading:   Bool = false
    @State private var lastRefresh: Date? = nil
    @State private var errorMessage: String? = nil
    @State private var sortOrder:   SortField = .port
    @State private var filterText:  String = ""

    enum SortField: String, CaseIterable {
        case port    = "Port"
        case process = "Process"
        case exposure = "Exposure"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            filterBar
            Divider()
            if isLoading && ports.isEmpty {
                loadingView
            } else if let err = errorMessage {
                errorView(err)
            } else if ports.isEmpty {
                emptyView
            } else {
                portTable
            }
        }
        .onAppear { refresh() }
        if !ports.isEmpty {
            Divider()
            ClaudeCompanionCard(
                context: openPortsClaudeContext(),
                promptHint: openPortsClaudeHint()
            )
            .padding(16)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.open.display")
                .font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Open Ports — This Mac")
                    .font(.headline)
                if let refresh = lastRefresh {
                    Text("Last scanned \(refresh, style: .relative) ago · \(ports.count) listening")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("TCP listening sockets on this machine")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.7)
            }
            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help("Rescan listening ports")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Filter / sort bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary).font(.caption)
                    TextField("Filter by port, process, or address…", text: $filterText)
                        .textFieldStyle(.plain).font(.caption)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .frame(maxWidth: 280)

                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortField.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Spacer()
            }

            exposureLegend
                .padding(.leading, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var exposureLegend: some View {
        HStack(spacing: 10) {
            ForEach([
                ("circle.fill", Color.secondary, "Loopback"),
                ("circle.fill", Color.blue,      "Well-known"),
                ("circle.fill", Color.green,     "Specific IF"),
                ("circle.fill", Color.orange,    "All IFs"),
            ], id: \.2) { icon, color, label in
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 6)).foregroundStyle(color)
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Port table

    private var portTable: some View {
        VStack(spacing: 0) {
            portColumnHeader
            Divider()
            List {
                ForEach(filteredSorted) { port in
                    PortRow(port: port)
                }
            }
            .listStyle(.plain)
            Divider()
            HStack {
                let exposed = filteredSorted.filter { $0.exposure == .exposed }.count
                Text("\(filteredSorted.count) sockets")
                    .font(.caption2).foregroundStyle(.secondary)
                if exposed > 0 {
                    Text("·")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("\(exposed) bound to all interfaces")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private var portColumnHeader: some View {
        HStack(spacing: 0) {
            Text("  ").frame(width: 20)
            Text("Port").frame(width: 60, alignment: .leading)
            Text("Proto").frame(width: 50, alignment: .leading)
            Text("Address").frame(width: 130, alignment: .leading)
            Text("Process").frame(width: 140, alignment: .leading)
            Text("PID").frame(width: 60, alignment: .leading)
            Text("Service").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var filteredSorted: [ListeningPort] {
        var result = ports

        // Filter
        if !filterText.isEmpty {
            let q = filterText.lowercased()
            result = result.filter {
                $0.process.lowercased().contains(q)
                || "\($0.port)".contains(q)
                || $0.address.lowercased().contains(q)
                || $0.serviceHint.lowercased().contains(q)
            }
        }

        // Sort
        switch sortOrder {
        case .port:
            result.sort { $0.port < $1.port }
        case .process:
            result.sort { $0.process.lowercased() < $1.process.lowercased() }
        case .exposure:
            let order: [PortExposure] = [.exposed, .wellKnown, .bound, .loopback]
            result.sort {
                let ai = order.firstIndex(of: $0.exposure) ?? 99
                let bi = order.firstIndex(of: $1.exposure) ?? 99
                return ai == bi ? $0.port < $1.port : ai < bi
            }
        }

        // Deduplicate (lsof may return both IPv4 and IPv6 entries for the same bind)
        var seen = Set<String>()
        result = result.filter { p in
            let key = "\(p.pid)-\(p.port)-\(p.address)"
            return seen.insert(key).inserted
        }

        return result
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning listening ports…").foregroundStyle(.secondary).font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle).foregroundStyle(.orange)
            Text("Could not scan ports").font(.headline)
            Text(msg).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            Button("Retry") { refresh() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.display")
                .font(.system(size: 40)).foregroundStyle(.green)
            Text("No listening ports found").font(.headline)
            Text("No TCP services appear to be listening on this Mac.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Claude context

    private func openPortsClaudeContext() -> String {
        let exposed   = ports.filter { $0.exposure == .exposed }
        let wellKnown = ports.filter { $0.exposure == .wellKnown }
        let loopback  = ports.filter { $0.exposure == .loopback }
        var lines = [
            "## NetWatch Open Ports — This Mac",
            "Total TCP listening: \(ports.count)",
            "Bound to all interfaces (⚠️ exposed): \(exposed.count)",
            "Well-known ports: \(wellKnown.count)",
            "Loopback only: \(loopback.count)"
        ]
        if !exposed.isEmpty {
            lines.append("")
            lines.append("Exposed ports (all interfaces):")
            for p in exposed.sorted(by: { $0.port < $1.port }) {
                let hint = p.serviceHint.isEmpty ? "" : " — \(p.serviceHint)"
                lines.append("  Port \(p.port)/\(p.proto) [\(p.address)]: \(p.process) (PID \(p.pid))\(hint)")
            }
        }
        if !wellKnown.isEmpty {
            lines.append("")
            lines.append("Well-known ports (specific interface):")
            for p in wellKnown.sorted(by: { $0.port < $1.port }).prefix(8) {
                let hint = p.serviceHint.isEmpty ? "" : " — \(p.serviceHint)"
                lines.append("  Port \(p.port): \(p.process)\(hint)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func openPortsClaudeHint() -> String {
        let exposed = ports.filter { $0.exposure == .exposed }
        if !exposed.isEmpty {
            let portList = exposed.prefix(3).map { "\($0.port)" }.joined(separator: ", ")
            return "I have \(exposed.count) port(s) bound to all interfaces: \(portList). Are any of these a security risk I should address?"
        }
        return "I have \(ports.count) TCP listening ports on this Mac. Are there any that look suspicious or unnecessary?"
    }

    // MARK: - Scan

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            let result = Self.scanPorts()
            await MainActor.run {
                switch result {
                case .success(let p):
                    self.ports       = p
                    self.lastRefresh = Date()
                    self.errorMessage = nil
                case .failure(let e):
                    self.errorMessage = e.localizedDescription
                }
                self.isLoading = false
            }
        }
    }

    private static func scanPorts() -> Result<[ListeningPort], Error> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -n: no DNS lookup  -P: no port-name lookup  -iTCP: TCP only  -sTCP:LISTEN: listening only
        proc.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()   // discard stderr

        do { try proc.run() } catch {
            return .failure(error)
        }
        let data   = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let raw = String(data: data, encoding: .utf8) else {
            return .success([])
        }

        var ports: [ListeningPort] = []
        let lines = raw.components(separatedBy: "\n").dropFirst()  // skip header

        for line in lines {
            guard !line.isEmpty else { continue }
            // lsof columns: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [STATE]
            // NAME field: "*:7000 (LISTEN)" — lsof appends " (LISTEN)" even with -sTCP:LISTEN.
            // Last column is "(LISTEN)"; addr:port is second-to-last when state is present.
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9 else { continue }

            let command = String(cols[0])
            guard let pid = Int(cols[1]) else { continue }
            // Strip trailing "(STATE)" token if present so we get the addr:port field.
            let rawLast = String(cols[cols.count - 1])
            let nameField = rawLast.hasPrefix("(") ? String(cols[cols.count - 2]) : rawLast

            // Parse address:port from NAME
            let (addr, port) = parseAddressPort(nameField)
            guard let portNum = port, portNum > 0 else { continue }

            let isLoopback = addr.hasPrefix("127.") || addr == "::1" || addr == "localhost"
            let isWildcard = addr == "*" || addr == "0.0.0.0" || addr == "::"

            ports.append(ListeningPort(
                process:    command,
                pid:        pid,
                proto:      "TCP",
                address:    addr,
                port:       portNum,
                isLoopback: isLoopback,
                isWildcard: isWildcard
            ))
        }

        return .success(ports)
    }

    /// Parse "address:port" or "*:port" or "[::1]:port" from lsof NAME field.
    private static func parseAddressPort(_ name: String) -> (String, Int?) {
        // IPv6 bracketed: [::1]:5432
        if name.hasPrefix("[") {
            if let bracketEnd = name.firstIndex(of: "]") {
                let addr = String(name[name.index(after: name.startIndex)..<bracketEnd])
                let rest = String(name[name.index(after: bracketEnd)...])
                let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
                return (addr, port)
            }
        }
        // Standard: addr:port or *:port
        let parts = name.components(separatedBy: ":")
        if parts.count == 2 {
            return (parts[0], Int(parts[1]))
        }
        return (name, nil)
    }
}

// MARK: - Port Row

private struct PortRow: View {
    let port: ListeningPort

    var body: some View {
        HStack(spacing: 0) {
            // Exposure dot
            Circle()
                .fill(exposureColor)
                .frame(width: 7, height: 7)
                .frame(width: 20)

            Text("\(port.port)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(exposureColor)
                .frame(width: 60, alignment: .leading)

            Text(port.proto)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            Text(port.address.isEmpty ? "*" : port.address)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)

            Text(port.process)
                .font(.body)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            Text("\(port.pid)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            if !port.serviceHint.isEmpty {
                Text(port.serviceHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(port.exposure == .exposed ? Color.orange.opacity(0.04) : Color.clear)
        .contextMenu {
            Button("Copy Port") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(port.port)", forType: .string)
            }
            Button("Copy Process") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(port.process, forType: .string)
            }
            Divider()
            Button("Copy lsof Line") {
                let s = "\(port.process) (PID \(port.pid))  \(port.proto) \(port.address):\(port.port)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
    }

    private var exposureColor: Color {
        switch port.exposure {
        case .loopback:  return .secondary
        case .wellKnown: return .blue
        case .bound:     return .green
        case .exposed:   return .orange
        }
    }
}
