/// ConnectorProtocol.swift — NetWatch Device Connector API
///
/// Defines the protocol that every device connector must implement. This is the
/// extension point: anyone can add support for a new router, firewall, or network
/// appliance by creating a class that conforms to `DeviceConnector` and registering
/// it with `ConnectorRegistry.shared`.
///
/// Built-in connectors: FirewallaConnector, NightawkConnector.
/// To add your own: see ConnectorRegistry.swift and the "Adding Connectors" section
/// in the repo README.

import Foundation

// MARK: - Core Protocol

/// A device connector reads live data from a network appliance (router, firewall,
/// switch, etc.) and vends it as a `ConnectorSnapshot` every poll cycle.
///
/// Conforming types are instantiated by `ConnectorRegistry` from a stored
/// `ConnectorConfig`. All async work must be safe to call from a Swift Task; the
/// `ConnectorManager` dispatches calls off the main actor.
protocol DeviceConnector: AnyObject {
    /// Stable identifier — must match the id used to register with `ConnectorRegistry`.
    var id: String { get }

    /// Human-readable name shown in the UI (e.g. "Firewalla Gold").
    var displayName: String { get }

    /// SF Symbol name for the connector's icon.
    var iconName: String { get }

    /// Current configuration (host, credentials, etc.).
    var config: ConnectorConfig { get }

    /// Whether the last attempt to reach the device succeeded.
    var isConnected: Bool { get }

    /// Error message from the most recent failed fetch, if any.
    var lastError: String? { get }

    /// Most-recently fetched snapshot. nil until first successful poll.
    var lastSnapshot: ConnectorSnapshot? { get }

    /// Apply a new configuration. Called whenever the user saves Preferences.
    func configure(_ config: ConnectorConfig)

    /// Test connectivity without a full data fetch. Returns a brief status string
    /// on success (e.g. "Firewalla Gold Pro · firmware 1.974") or an error.
    func testConnection() async -> Result<String, Error>

    /// Fetch a full data snapshot. Called by `ConnectorManager` on the poll timer.
    func fetchSnapshot() async throws -> ConnectorSnapshot
}

// MARK: - Config

/// Serializable configuration for one connector instance. Stored in MonitorSettings
/// (UserDefaults). Sensitive fields (apiKey, password) are stored in plaintext here
/// for simplicity; for shared machines consider moving them to Keychain using the
/// `SecureStorage` helper in this file.
struct ConnectorConfig: Codable, Identifiable, Hashable {
    /// Must match a registered `ConnectorDescriptor.id`.
    var id: String
    var enabled: Bool       = false
    var host: String        = ""        // IP or hostname, no scheme
    var port: Int           = 0         // 0 = use connector default
    var apiKey: String      = ""        // bearer token / box token
    var username: String    = ""        // for basic-auth connectors
    var password: String    = ""        // for basic-auth connectors

    /// Free-form extras for connectors that need additional parameters.
    /// Keys are connector-defined (e.g. "snmp_community", "vlan_id").
    var extras: [String: String] = [:]
}

// MARK: - Snapshot & Metrics

/// A point-in-time capture from a device connector. Written to incident bundles
/// alongside ping/DNS data so you can correlate router events with network failures.
struct ConnectorSnapshot {
    let connectorId:   String
    let connectorName: String
    let timestamp:     Date
    let metrics:       [ConnectorMetric]   // numeric KPIs
    let events:        [ConnectorEvent]    // alerts, blocks, reboots, etc.
    let summary:       String              // one-paragraph human-readable description
}

/// A single numeric measurement from a connector (bandwidth, CPU load, etc.).
struct ConnectorMetric: Codable {
    let key:   String   // machine-readable (e.g. "wan_rx_mbps")
    let label: String   // display name (e.g. "WAN RX")
    let value: Double
    let unit:  String   // "Mbps", "%", "ms", etc.
    var severity: MetricSeverity = .ok
}

/// A discrete event from a connector (new device, blocked threat, WAN reconnect…).
struct ConnectorEvent: Codable {
    let timestamp:   Date
    let type:        String   // e.g. "alarm", "device_join", "wan_reconnect"
    let description: String
    var severity:    MetricSeverity = .info
}

enum MetricSeverity: String, Codable {
    case ok, info, warning, critical, unknown
    var color: String {
        switch self {
        case .ok:       return "green"
        case .info:     return "blue"
        case .warning:  return "yellow"
        case .critical: return "red"
        case .unknown:  return "secondary"
        }
    }
}

// MARK: - Registry Descriptor

/// Metadata about a connector type — used to populate the Preferences UI without
/// instantiating the connector.
struct ConnectorDescriptor: Identifiable {
    let id:          String
    let displayName: String
    let iconName:    String
    let description: String
    let vendor:      String
    let docsURL:     String?        // link to connector setup guide
    let configHelp:  ConnectorConfigHelp
}

struct ConnectorConfigHelp {
    let hostPlaceholder:   String   // shown as TextField placeholder
    let hostHelp:          String   // one-line tip (e.g. "Local IP of your Firewalla")
    let apiKeyLabel:       String   // label for the API key field
    let apiKeyHelp:        String
    let usernameLabel:     String
    let passwordLabel:     String
    let showCredentials:   Bool     // false for token-only connectors
}

// MARK: - Keychain helper (optional upgrade path)

/// Thin Keychain wrapper. Use this if you want to store connector credentials
/// outside UserDefaults — especially useful on shared machines or if you export
/// your NetWatch settings JSON.
///
/// Usage:
///   SecureStorage.save(apiKey, key: "connector.firewalla.apiKey")
///   let key = SecureStorage.load(key: "connector.firewalla.apiKey")
enum SecureStorage {
    private static let service = "com.louisswingrover.netwatch"

    static func save(_ value: String, key: String) {
        let data = Data(value.utf8)
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: key as CFString,
            kSecValueData:   data
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: key as CFString,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: key as CFString
        ]
        SecItemDelete(q as CFDictionary)
    }
}
