/// ConnectionState.swift — Published state machine for Mac API connectivity + away mode
///
/// Owns the polling loop. Views observe this object directly.

import Foundation
import Combine

enum ConnectionMode: Equatable {
    case unconfigured           // No Mac IP set
    case connecting             // First connection attempt in progress
    case connected              // Reachable; isHome indicates LAN vs. VPN
    case away                   // Reachable via VPN; device is off home LAN
    case error(String)          // Last fetch failed

    var isConnected: Bool {
        if case .connected = self { return true }
        if case .away = self      { return true }
        return false
    }

    var label: String {
        switch self {
        case .unconfigured:       return "Not configured"
        case .connecting:         return "Connecting…"
        case .connected:          return "Home network"
        case .away:               return "Away (VPN)"
        case .error(let msg):     return "Offline — \(msg)"
        }
    }

    var systemImage: String {
        switch self {
        case .unconfigured:   return "wifi.slash"
        case .connecting:     return "arrow.clockwise"
        case .connected:      return "house.fill"
        case .away:           return "arrow.triangle.2.circlepath"
        case .error:          return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
class ConnectionState: ObservableObject {

    // MARK: - Published state

    @Published var mode:       ConnectionMode = .unconfigured
    @Published var health:     APIHealthPayload?
    @Published var connectors: [APIConnectorPayload] = []
    @Published var status:     APIStatusPayload?
    @Published var incidents:  [APIIncidentSummary] = []
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    // MARK: - Dependencies

    let client: APIClient

    // MARK: - Private

    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 15  // seconds between refreshes

    // MARK: - Init

    init(client: APIClient) {
        self.client = client
        if !client.macIP.isEmpty { mode = .connecting }
    }

    // MARK: - Lifecycle

    func startPolling() {
        guard !client.macIP.isEmpty else { mode = .unconfigured; return }
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Refresh

    func refresh() async {
        guard !client.macIP.isEmpty else { mode = .unconfigured; return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            // Fetch all four endpoints concurrently
            async let healthFetch     = client.fetchHealth()
            async let connFetch       = client.fetchConnectors()
            async let statusFetch     = client.fetchStatus()
            async let incidentFetch   = client.fetchIncidents()

            let (h, c, s, i) = try await (healthFetch, connFetch, statusFetch, incidentFetch)

            health     = h
            connectors = c.sorted { $0.name < $1.name }
            status     = s
            incidents  = i
            lastUpdated = Date()

            // Away mode detection: compare Mac's public IP vs. device's public IP
            await detectAwayMode(macPublicIP: s.macPublicIP)

        } catch {
            let msg = (error as? APIClientError)?.errorDescription ?? error.localizedDescription
            mode = .error(msg)
        }
    }

    // MARK: - Away Mode

    private func detectAwayMode(macPublicIP: String) async {
        // If we can't detect the device IP, assume connected (less disruptive)
        guard let deviceIP = await client.fetchDevicePublicIP() else {
            mode = .connected
            return
        }
        mode = (deviceIP == macPublicIP) ? .connected : .away
    }

    // MARK: - Config change

    /// Call after the user updates macIP/macPort in Settings.
    func reconfigure() {
        client.saveConfig()
        stopPolling()
        mode = .connecting
        startPolling()
    }
}
