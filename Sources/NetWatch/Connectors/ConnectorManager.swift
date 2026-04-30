/// ConnectorManager.swift — NetWatch Device Connector Manager
///
/// Owns the live connector instances, runs the poll timer, and vends current
/// snapshots to the SwiftUI layer. Injected into NetworkMonitorService so the
/// IncidentManager can include connector data in incident bundles.
///
/// Poll cycle: every 30 seconds (configurable). Individual connectors time out
/// after 10 seconds per fetch so a dead device can't stall the cycle.

import Foundation
import Combine

@MainActor
final class ConnectorManager: ObservableObject {

    // MARK: - Published state (drives ConnectorsView)

    /// Live connector instances, one per enabled config. Rebuilt on settings change.
    @Published private(set) var connectors: [any DeviceConnector] = []

    /// Latest snapshot per connector id. Empty until first successful poll.
    @Published private(set) var snapshots: [String: ConnectorSnapshot] = [:]

    /// True while a poll cycle is in flight.
    @Published private(set) var isPolling = false

    // MARK: - Config

    var pollInterval: TimeInterval = 30.0

    // MARK: - Private

    private var pollTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Apply a new set of connector configs (called when user saves Preferences).
    /// Tears down existing connectors and rebuilds from the enabled subset.
    func load(configs: [ConnectorConfig]) {
        // Stop any running poll
        pollTask?.cancel()
        pollTask = nil

        // Instantiate one connector per enabled, registered config
        connectors = configs
            .filter(\.enabled)
            .compactMap { cfg in
                ConnectorRegistry.shared.make(cfg.id, config: cfg)
            }

        // Resume polling if we have connectors
        if !connectors.isEmpty {
            startPolling()
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            // Initial poll immediately, then on interval
            await pollAll()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await pollAll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Force an immediate poll of all connectors (e.g. user taps "Refresh").
    func pollNow() {
        Task { await pollAll() }
    }

    // MARK: - Polling

    private func pollAll() async {
        guard !connectors.isEmpty else { return }
        isPolling = true
        defer { isPolling = false }

        // Poll connectors sequentially. Each call has a built-in timeout (set in
        // the connector implementation). Parallel polling is possible but sequential
        // is safer for routers that struggle with concurrent requests.
        for connector in connectors {
            guard !Task.isCancelled else { break }
            do {
                let snapshot = try await withTimeout(seconds: 20) {
                    try await connector.fetchSnapshot()
                }
                snapshots[connector.id] = snapshot
            } catch {
                // Failed fetch — connector updates its own lastError; we just skip.
            }
        }
    }

    // MARK: - Snapshot access

    /// Returns all current snapshots in connector-list order.
    var allSnapshots: [ConnectorSnapshot] {
        connectors.compactMap { snapshots[$0.id] }
    }

    /// Returns the snapshot for a specific connector id.
    func snapshot(for id: String) -> ConnectorSnapshot? {
        snapshots[id]
    }
}

// MARK: - Timeout helper

/// Races a task against a deadline. Throws `TimeoutError` if the deadline fires first.
func withTimeout<T: Sendable>(seconds: Double,
                               operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error, LocalizedError {
    var errorDescription: String? { "Request timed out" }
}
