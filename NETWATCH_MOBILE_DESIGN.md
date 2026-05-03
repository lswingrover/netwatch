# NetWatch Mobile — Design Document

## Architecture Decision: Mac as Relay Hub

### Why direct connection doesn't work

All three connectors rely on SSH or Python scripts running on the Mac:

| Connector | How it works | iOS-native? |
|-----------|-------------|-------------|
| Firewalla | SSH → Redis via paramiko | ❌ No SSH on iOS |
| CM3000 | SSH tunnel → HTTPS scrape | ❌ No SSH on iOS |
| Orbi | URLSession HTTPS SOAP | ✅ Works natively |

Rewriting SSH in Swift for iOS is possible but expensive and fragile. The better path:
**Mac runs the heavy work; iOS app is a lightweight client.**

### The Relay Architecture

```
Home Network (LAN or VPN tunnel)
                    ┌─────────────────────────────────────────────┐
                    │  Mac (NetWatch running)                      │
                    │  ┌───────────┐  ┌──────────┐  ┌──────────┐ │
                    │  │Firewalla  │  │ CM3000   │  │  Orbi    │ │
                    │  │SSH→Redis  │  │SSH+SOAP  │  │  SOAP    │ │
                    │  └───────────┘  └──────────┘  └──────────┘ │
                    │         ↓             ↓              ↓       │
                    │  ┌──────────────────────────────────────┐   │
                    │  │  NetWatch API (HTTP on :57821)        │   │
                    │  │  GET /health    → stack health JSON   │   │
                    │  │  GET /connectors → all connector data │   │
                    │  │  GET /incidents  → recent incidents   │   │
                    │  └──────────────────────────────────────┘   │
                    └─────────────────────────────────────────────┘
                                    ↑ HTTP (LAN or WireGuard VPN)
                    ┌───────────────────────────────┐
                    │  iPhone / iPad (NetWatch iOS)  │
                    │  Home network:  192.168.x.x   │
                    │  Away + VPN:    10.x.x.x      │
                    └───────────────────────────────┘
```

### Why this is the right call

- Zero duplication: Mac handles all SSH/Python; iOS just renders JSON
- Works when away: WireGuard VPN tunnels back to home → iOS still reaches Mac API
- Incremental: Orbi can later connect natively (SOAP works on iOS); others stay relay
- Simple: No extra auth tokens, no cloud sync, no Firebase

---

## API Endpoints (Sprint 9 → build into NetWatch Mac)

The Mac side exposes a lightweight HTTP server on `localhost:57821` (or configurable port).
All endpoints return JSON. No auth needed (LAN-local only; WireGuard provides transport security).

```
GET /health
→ { "score": 87, "status": "healthy", "timestamp": "...", "layers": {...} }

GET /connectors
→ { "firewalla": {...snapshot...}, "cm3000": {...}, "orbi": {...} }

GET /incidents
→ [ { "id": "...", "timestamp": "...", "severity": "...", "rootCause": "..." }, ... ]

GET /status
→ { "isRunning": true, "publicIP": "...", "wifiSSID": "...", "gatewayRTT": 1.2 }
```

### Mac-side implementation sketch

Add to `NetworkMonitorService`:
```swift
// NetWatchAPIServer.swift
final class NetWatchAPIServer {
    private let port: UInt16 = 57_821
    private var listener: NWListener?

    func start(snapshotProvider: @escaping () -> APIPayload) {
        let params = NWParameters.tcp
        listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { connection in
            self.handle(connection: connection, snapshotProvider: snapshotProvider)
        }
        listener?.start(queue: .global(qos: .utility))
    }
    // handle GET / route based on path, return JSON
}
```

Use `Network.framework` (NWListener) — no third-party dependencies needed.

---

## iOS App Structure

```
NetWatchMobile/
├── NetWatchMobileApp.swift          — @main, injects APIClient
├── ContentView.swift                — TabView: Overview | Connectors | Incidents
├── Views/
│   ├── MobileOverviewView.swift     — Health score + 3 connector tiles + away mode banner
│   ├── MobileConnectorDetail.swift  — Firewalla/CM3000/Orbi detail (read-only)
│   ├── MobileIncidentsView.swift    — Incident list, sorted by date
│   └── MobileSettingsView.swift     — Mac IP + port config, test connection
├── Models/
│   ├── APIClient.swift              — URLSession wrapper for Mac API
│   ├── APIModels.swift              — Codable structs matching Mac JSON
│   └── ConnectionState.swift       — published state: connected/away/offline
└── Widgets/
    ├── NetWatchWidget.swift         — Health score lock screen / home screen widget
    └── NetWatchWidgetExtension.swift
```

---

## Home Screen / Lock Screen Widget

**Lock Screen (WidgetKit, iOS 16+)**
- Shows: health score (0–100) + status dot (green/yellow/red)
- Updates: on demand (user triggers) + background refresh every 15 min

**Home Screen Small Widget**
- Health score + 3 key metric dots (WAN ✅, Modem ✅/⚠️, Firewalla ✅)
- Tap opens app to Overview tab

**Home Screen Medium Widget**
- Health score bar + 3 connector rows with key metrics

---

## Away Mode on Mobile

The iOS app detects away mode by:
1. Connecting to Mac API → getting `homePublicIP` from the status endpoint
2. Querying `https://ifconfig.me` on device → device's current public IP
3. If different → "Away Mode" banner: "You're off home network"
4. If WireGuard is active → detected by `NEVPNManager.shared().connection.status == .connected`

When away without VPN, the app shows:
- A "Connect to home VPN" nudge
- The last cached snapshot (with age indicator)
- Instructions to activate WireGuard profile

---

## Notification Strategy

The Mac app pushes notifications via iOS notification forwarding:
- Option A: Pushover / Prowl API — easiest, zero infrastructure
- Option B: Apple Push Notifications (APNs) via a tiny Vapor/Hummingbird server
- Option C: Local notifications on Mac that also appear on linked iPhone via Handoff

**Recommended for v1:** Pushover. Louis already has the infrastructure mindset.
Config: add `PUSHOVER_USER_KEY` + `PUSHOVER_APP_TOKEN` to `~/.env`.
Mac sends HTTP POST to `https://api.pushover.net/1/messages.json` when:
- Stack health drops below 60 (degraded)
- CM3000 upstream TX > 51 dBmV
- New CYBER_ alarm on Firewalla
- Incident auto-triggered

---

## Implementation Phases

### Phase A — Mac API server (2–3 hrs)
1. `NetWatchAPIServer.swift` using NWListener
2. JSON serializers for ConnectorSnapshot, IncidentBundles, StackHealth
3. Settings UI to enable/disable API + show port
4. Test via `curl http://localhost:57821/health`

### Phase B — iOS app skeleton (3–4 hrs)
1. New Xcode target `NetWatchMobile` (iOS 17+)
2. `APIClient.swift` + `APIModels.swift`
3. `MobileOverviewView`: health score ring + connector tiles + away mode detection
4. `MobileSettingsView`: enter Mac IP + test connection

### Phase C — Widgets (2 hrs)
1. WidgetKit extension
2. Lock Screen + Home Screen small/medium variants
3. Background refresh via `URLSession` background task

### Phase D — Pushover notifications (1 hr)
1. `PushoverAlerter.swift` in Mac app
2. Hook into existing incident detection
3. Settings toggle: enable/disable, test notification

---

## Key Constraints

- **iOS app requires Mac to be on and running** — this is a feature (single source of truth), not a bug
- **Orbi can eventually go native** — URLSession SOAP works on iOS; no SSH needed
- **CM3000 stays relay** — SSH tunnel is non-trivial; relay is correct approach
- **No App Store (initially)** — sideload via Xcode or TestFlight; this is a personal tool
- **WireGuard** is the security layer when away — NetWatch Mobile assumes VPN is configured

---

## Next Build Step

Start with **Phase A**: Add `NetWatchAPIServer.swift` to the Mac app.
The iOS app is worthless until it has an API to talk to.
