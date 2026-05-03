/// NetWatchAPIServer.swift — Lightweight local HTTP API for NetWatch Mobile
///
/// Exposes a read-only JSON API on 127.0.0.1:57821 (configurable).
/// This allows NetWatch iOS to query current connector state without repeating
/// all the SSH/Python work. The iOS app connects directly when on the home LAN
/// or through the WireGuard VPN tunnel when away.
///
/// Endpoints:
///   GET /health     → stack health score + layer status
///   GET /connectors → all connector snapshots + intelligence data
///   GET /status     → MAC interface state, public IP, uptime
///   GET /incidents  → last 10 incidents (summary)
///
/// Security: listens on all interfaces (0.0.0.0) so the iOS app can reach it
/// from the same LAN or via VPN. No auth token — WireGuard is the security layer.
/// The port is 57821 (NETWATCH → N=14 E=5 T=20 W=23 A=1 T=20 C=3 H=8, sum=94 ≈ 57821 mnemonic).

import Foundation
import Network

// MARK: - Payload types (Codable for JSON serialisation)

struct APIHealthPayload: Codable {
    let score:     Int
    let status:    String     // "healthy" | "degraded" | "critical"
    let timestamp: String
    let layers:    [String: String]   // layer → "ok" | "warning" | "critical"
}

struct APIConnectorPayload: Codable {
    let id:          String
    let name:        String
    let connected:   Bool
    let lastUpdated: String?
    let summary:     String?
    let error:       String?
    let metrics:     [APIMetric]
    let events:      [APIEvent]
}

struct APIMetric: Codable {
    let key:      String
    let label:    String
    let value:    Double
    let unit:     String
    let severity: String  // "ok" | "info" | "warning" | "critical"
}

struct APIEvent: Codable {
    let timestamp:   String
    let type:        String
    let description: String
    let severity:    String
}

struct APIStatusPayload: Codable {
    let macPublicIP:   String
    let macLocalIP:    String
    let wifiSSID:      String
    let gatewayRTT:    Double?
    let isMonitoring:  Bool
    let appVersion:    String
}

struct APIIncidentSummary: Codable {
    let id:          String
    let timestamp:   String
    let healthScore: Int
    let rootCause:   String
    let severity:    String
}

// MARK: - Server

@MainActor
final class NetWatchAPIServer {

    // MARK: - Dependencies (injected on start)

    typealias SnapshotProvider = () -> [ConnectorSnapshot]
    typealias StatusProvider   = () -> APIStatusPayload
    typealias HealthProvider   = () -> APIHealthPayload
    typealias IncidentProvider = () -> [APIIncidentSummary]

    var snapshotProvider: SnapshotProvider = { [] }
    var statusProvider:   StatusProvider   = { APIStatusPayload(macPublicIP: "", macLocalIP: "", wifiSSID: "", gatewayRTT: nil, isMonitoring: false, appVersion: "1.x") }
    var healthProvider:   HealthProvider   = { APIHealthPayload(score: 0, status: "unknown", timestamp: "", layers: [:]) }
    var incidentProvider: IncidentProvider = { [] }

    // MARK: - State

    private var listener:    NWListener?
    private var connections: [NWConnection] = []
    var isRunning: Bool = false
    var port: UInt16 = 57_821

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("[NetWatchAPI] Invalid port \(port)")
            return
        }

        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            print("[NetWatchAPI] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            // NWListener callbacks run on its queue — hop to MainActor
            Task { @MainActor [weak self] in
                self?.acceptConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { [weak self] state in
            // NWListener callbacks run on its queue — hop to MainActor
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isRunning = true
                    print("[NetWatchAPI] Listening on :\(self?.port ?? 0)")
                case .failed(let error):
                    self?.isRunning = false
                    print("[NetWatchAPI] Listener failed: \(error)")
                default: break
                }
            }
        }

        listener?.start(queue: DispatchQueue(label: "netwatch.api.listener", qos: .utility))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isRunning = false
    }

    // MARK: - Connection handling

    private func acceptConnection(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: DispatchQueue(label: "netwatch.api.conn", qos: .utility))

        // Read incoming HTTP request (cap at 4 KB — headers only)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.handleRequest(request, connection: connection)
        }
    }

    private func handleRequest(_ raw: String, connection: NWConnection) {
        // Parse the request line: "GET /path HTTP/1.1"
        let firstLine = raw.components(separatedBy: "\r\n").first ?? ""
        let parts     = firstLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendResponse(connection: connection, status: 405, body: #"{"error":"Method Not Allowed"}"#)
            return
        }

        let path = parts[1].components(separatedBy: "?").first ?? parts[1]

        Task { @MainActor [weak self] in
            guard let self else { return }
            let (status, body) = self.route(path: path)
            self.sendResponse(connection: connection, status: status, body: body)
            // Remove from active list after responding
            self.connections.removeAll { $0 === connection }
        }
    }

    @MainActor
    private func route(path: String) -> (Int, String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        switch path {
        case "/", "/health":
            let payload = healthProvider()
            return encode(payload, encoder: encoder)

        case "/connectors":
            let snapshots = snapshotProvider()
            let payloads  = snapshots.map { connectorPayload(from: $0) }
            return encode(payloads, encoder: encoder)

        case "/status":
            let payload = statusProvider()
            return encode(payload, encoder: encoder)

        case "/incidents":
            let payload = incidentProvider()
            return encode(payload, encoder: encoder)

        case "/ping":
            return (200, #"{"pong":true}"#)

        default:
            return (404, #"{"error":"Not found","paths":["/health","/connectors","/status","/incidents","/ping"]}"#)
        }
    }

    private func connectorPayload(from snap: ConnectorSnapshot) -> APIConnectorPayload {
        APIConnectorPayload(
            id:          snap.connectorId,
            name:        snap.connectorName,
            connected:   true,
            lastUpdated: ISO8601DateFormatter().string(from: snap.timestamp),
            summary:     snap.summary,
            error:       nil,
            metrics:     snap.metrics.map { m in
                APIMetric(
                    key:      m.key,
                    label:    m.label,
                    value:    m.value,
                    unit:     m.unit,
                    severity: m.severity.rawValue
                )
            },
            events: snap.events.prefix(20).map { e in
                APIEvent(
                    timestamp:   ISO8601DateFormatter().string(from: e.timestamp),
                    type:        e.type,
                    description: e.description,
                    severity:    e.severity.rawValue
                )
            }
        )
    }

    // MARK: - HTTP response

    private func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusText: String = {
            switch status {
            case 200: return "OK"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            default:  return "Error"
            }
        }()

        let response = """
            HTTP/1.1 \(status) \(statusText)\r\n\
            Content-Type: application/json\r\n\
            Content-Length: \(body.utf8.count)\r\n\
            Access-Control-Allow-Origin: *\r\n\
            Connection: close\r\n\
            \r\n\
            \(body)
            """

        guard let data = response.data(using: .utf8) else { connection.cancel(); return }

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Helpers

    private func encode<T: Encodable>(_ value: T, encoder: JSONEncoder) -> (Int, String) {
        do {
            let data = try encoder.encode(value)
            return (200, String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            return (500, #"{"error":"Encoding failed"}"#)
        }
    }
}

// MARK: - MetricSeverity rawValue extension

extension MetricSeverity {
    var rawValue: String {
        switch self {
        case .ok:       return "ok"
        case .info:     return "info"
        case .warning:  return "warning"
        case .critical: return "critical"
        case .unknown:  return "unknown"
        }
    }
}
