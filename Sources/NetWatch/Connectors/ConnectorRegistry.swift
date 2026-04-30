/// ConnectorRegistry.swift — NetWatch Device Connector Registry
///
/// A singleton factory that maps connector IDs to descriptors + instantiation
/// closures. Built-in connectors (Firewalla, Nighthawk) are registered in
/// NetWatchApp.swift at launch. Third-party connectors can register themselves
/// the same way — no changes to core code required.
///
/// To add a new connector:
///   1. Create a class conforming to `DeviceConnector` (see FirewallaConnector.swift
///      as a reference implementation).
///   2. Define a `ConnectorDescriptor` with the connector's metadata and config help.
///   3. Call `ConnectorRegistry.shared.register(descriptor:factory:)` in NetWatchApp.
///   4. Add a `ConnectorConfig(id: "your-id")` to MonitorSettings.connectorConfigs
///      (done automatically when the user enables the connector in Preferences).

import Foundation

final class ConnectorRegistry {

    // MARK: - Singleton

    static let shared = ConnectorRegistry()
    private init() {}

    // MARK: - Storage

    private var factories:    [String: (ConnectorConfig) -> any DeviceConnector] = [:]
    private var descriptors:  [ConnectorDescriptor] = []

    // MARK: - Registration

    /// Register a connector type. Call once at app launch for each supported device.
    ///
    /// - Parameters:
    ///   - descriptor: Human-readable metadata shown in Preferences.
    ///   - factory:    Closure that produces a live instance from a stored config.
    func register(_ descriptor: ConnectorDescriptor,
                  factory: @escaping (ConnectorConfig) -> any DeviceConnector) {
        factories[descriptor.id]   = factory
        // Replace descriptor if already registered (useful for hot-reload in dev).
        if let idx = descriptors.firstIndex(where: { $0.id == descriptor.id }) {
            descriptors[idx] = descriptor
        } else {
            descriptors.append(descriptor)
        }
    }

    // MARK: - Instantiation

    /// Instantiate a connector from a stored config. Returns nil if the id is
    /// unregistered (e.g. a connector that was removed from the app).
    func make(_ id: String, config: ConnectorConfig) -> (any DeviceConnector)? {
        factories[id]?(config)
    }

    // MARK: - Discovery

    /// All registered connector descriptors, in registration order.
    var allDescriptors: [ConnectorDescriptor] { descriptors }

    /// Returns the descriptor for a given id, or nil if not registered.
    func descriptor(for id: String) -> ConnectorDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// True if the id is registered — used to filter stale configs in settings.
    func isRegistered(_ id: String) -> Bool {
        factories[id] != nil
    }
}
