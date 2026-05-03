/// APIClient.swift — URLSession wrapper for NetWatch Mac API
///
/// All fetch methods are async/throws. The caller owns retry logic.
/// Base URL is constructed from ConnectionState's macIP and macPort at call time.

import Foundation

enum APIClientError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case decodingError(Error)
    case networkError(Error)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:          return "Invalid Mac IP or port"
        case .httpError(let code): return "HTTP \(code)"
        case .decodingError:       return "Unexpected response format"
        case .networkError(let e): return e.localizedDescription
        case .timeout:             return "Connection timed out"
        }
    }
}

@MainActor
class APIClient: ObservableObject {

    // MARK: - Configuration

    /// Configurable via MobileSettingsView; persisted in UserDefaults.
    @Published var macIP:   String  = UserDefaults.standard.string(forKey: "nw_macIP")   ?? ""
    @Published var macPort: UInt16  = UInt16(UserDefaults.standard.integer(forKey: "nw_macPort").clamped(to: 1024...65535, default: 57821))

    func saveConfig() {
        UserDefaults.standard.set(macIP,            forKey: "nw_macIP")
        UserDefaults.standard.set(Int(macPort),     forKey: "nw_macPort")
    }

    // MARK: - Session (short timeout — we're on LAN or VPN)

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 5
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    // MARK: - Endpoints

    func fetchHealth() async throws -> APIHealthPayload {
        try await fetch("/health")
    }

    func fetchConnectors() async throws -> [APIConnectorPayload] {
        try await fetch("/connectors")
    }

    func fetchStatus() async throws -> APIStatusPayload {
        try await fetch("/status")
    }

    func fetchIncidents() async throws -> [APIIncidentSummary] {
        try await fetch("/incidents")
    }

    /// Quick connectivity test — returns true if the Mac API responds.
    func testConnection() async -> Bool {
        guard let url = makeURL("/ping") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Fetch the device's own public IP (used for away mode detection).
    func fetchDevicePublicIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private func makeURL(_ path: String) -> URL? {
        guard !macIP.isEmpty else { return nil }
        return URL(string: "http://\(macIP):\(macPort)\(path)")
    }

    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        guard let url = makeURL(path) else { throw APIClientError.invalidURL }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw APIClientError.timeout
        } catch {
            throw APIClientError.networkError(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIClientError.httpError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIClientError.decodingError(error)
        }
    }
}

// MARK: - Helpers

extension Int {
    func clamped(to range: ClosedRange<UInt16>, default defaultValue: UInt16) -> UInt16 {
        guard self >= Int(range.lowerBound), self <= Int(range.upperBound) else { return defaultValue }
        return UInt16(self)
    }
}
