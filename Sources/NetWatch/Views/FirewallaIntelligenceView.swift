/// FirewallaIntelligenceView.swift — Rich Firewalla data panel
///
/// Replaces the generic ConnectorDetailView for the Firewalla connector.
/// Surfaced from ConnectorsView when the selected connector id == "firewalla".
///
/// Tabs:
///   Devices   — full device list (online status, bandwidth, vendor, pause toggle)
///   Flows     — recent network flows (last 30 min, blocked highlighted)
///   Domains   — top DNS domains (last 24h)
///   Alarms    — Firewalla security alarms + events from snapshot

import SwiftUI

// MARK: - Root view

struct FirewallaIntelligenceView: View {

    @EnvironmentObject var connectorManager: ConnectorManager

    /// Convenience accessor — cast from the live connector list.
    private var firewalla: FirewallaConnector? {
        connectorManager.connectors.first(where: { $0.id == "firewalla" }) as? FirewallaConnector
    }

    private var snapshot: ConnectorSnapshot? {
        connectorManager.snapshot(for: "firewalla")
    }

    @State private var tab: FWTab = .devices
    @State private var deviceFilter: DeviceFilter = .all
    @State private var searchText: String = ""

    // Action feedback
    @State private var actionResult: ActionResult? = nil
    @State private var showActionBanner = false

    enum FWTab: String, CaseIterable {
        case devices = "Devices"
        case flows   = "Flows"
        case domains = "Domains"
        case alarms  = "Alarms"
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
                case .devices: devicesTab
                case .flows:   flowsTab
                case .domains: domainsTab
                case .alarms:  alarmsTab
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
