# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build (requires macOS 14+ SDK via Xcode Command Line Tools)
swift build

# Build + assemble .app + install to ~/Applications + launch
./build_app.sh

# Open in Xcode (preferred for UI work)
xed .

# Clean
swift package clean
```

No separate Xcode project file — SPM only. Two targets: `NetWatch` (macOS app) and `NetWatchMobile` (iOS companion).

The app installs to `~/Applications/NetWatch.app`. The build script handles icon generation, ad-hoc signing, Launch Services registration, and launch.

## Architecture

NetWatch is a macOS 14+ SwiftUI app for network performance monitoring. It mirrors the MacWatch codebase at `~/Developer/MacWatch` — same protocol-manager-registry pattern, just with network connectors instead of system sensors.

**Data flow:**
```
ConnectorRegistry → ConnectorManager (poll) → ConnectorProtocol.fetchSnapshot()
                                           → SnapshotStore (24h SQLite + memory)
                                           → NetworkMonitorService.@Published
                                           ↓
                  PingMonitor / DNSMonitor / TracerouteMonitor / InterfaceMonitor
                                           ↓
                              StackDiagnosisEngine → cross-layer diagnosis
                              IncidentManager → bundleIncident() → ~/network_tests/
                              RemediationEngine → DNS failover on failure
                              NetWatchNotificationManager → UNUserNotificationCenter
                              UpdateChecker → GitHub releases API
                              NetWatchAPIServer → /health /snapshot (NWListener)
                              MenuBarStatusView (NSStatusItem severity icon)
                              Views re-render
```

## Core Components

**ConnectorProtocol** (`Connectors/ConnectorProtocol.swift`) — implement `fetchSnapshot() async throws -> ConnectorSnapshot` to add a new device connector.

**ConnectorManager** (`Connectors/ConnectorManager.swift`) — `@MainActor ObservableObject`. Drives the poll cycle; calls `pollAll()` on a configurable interval. Sequential polling (not parallel) to prevent SSH tunnel conflicts between Firewalla and CM3000.

**ConnectorRegistry** (`Connectors/ConnectorRegistry.swift`) — call `registerAll()` once in `NetWatchApp.init()`. Add new connectors here.

**NetworkMonitorService** (`Monitors/NetworkMonitorService.swift`) — central `@Published` state hub. Owns `PingMonitor`, `DNSMonitor`, `TracerouteMonitor`, `InterfaceMonitor`, and `SpeedTestMonitor`. Entry point for all monitor observation in views.

**SnapshotStore** (`Monitors/SnapshotStore.swift`) — 24h rolling SQLite store in `~/Library/Application Support/NetWatch/netwatch.db`. Per-connector JSON snapshots keyed by timestamp. `history(connectorId:last:)` for charts.

**StackDiagnosisEngine** (`Monitors/StackDiagnosisEngine.swift`) — cross-layer root-cause analysis (physical → modem → router → mesh → DNS → application). Powers `/health` API endpoint and StackHealthView. `report()` returns a structured `StackDiagnosis` with layer statuses and human-readable root cause.

**IncidentManager** (`Monitors/IncidentManager.swift`) — cooldown-gated incident bundler. Writes `incident.txt` + `tier2_ticket.txt` ISP escalation draft to `~/network_tests/incidents/`. Resolves symlinks before all `String.write(to:atomically:)` calls to avoid silent failures on symlinked paths.

**RemediationEngine** (`Monitors/RemediationEngine.swift`) — auto-remediation: rotates system DNS resolver to Cloudflare/Google fallback on repeated ping failure; logs actions to the incident bundle.

**UpdateChecker** (`Monitors/UpdateChecker.swift`) — polls `api.github.com/repos/lswingrover/NetWatch/releases/latest` once per launch; semver comparison; fires a macOS notification and shows an in-app banner when a newer version is available.

**NetWatchAPIServer** (`Monitors/NetWatchAPIServer.swift`) — `NWListener`-based HTTP server (`/ping`, `/health`, `/snapshot`, `/events`, `/subscribe`, `/unsubscribe`). Started when `mobileAPIEnabled` is set in `MonitorSettings`. Runs on `@MainActor` to avoid actor-crossing isolation errors.

**BandwidthBudgetMonitor** (`Monitors/BandwidthBudgetMonitor.swift`) — tracks cumulative monthly data usage against a configurable budget; alerts on threshold crossings.

**WebhookAlerter** (`Monitors/WebhookAlerter.swift`) — sends incident payloads to a user-configured webhook URL on critical events.

## Monitors

| Monitor | Poll | Data Source | Key Metrics |
|---------|------|-------------|-------------|
| PingMonitor | continuous | ICMP via `ping` | RTT avg/p50/p95/p99, jitter, loss %, sparkline |
| DNSMonitor | per cycle | `dig` | query time per domain, multi-resolver (System/Cloudflare/Google/Quad9) |
| TracerouteMonitor | auto-cycling | `traceroute` | per-hop RTT bar chart, geo enrichment (ASN + city/country via ipapi.co) |
| InterfaceMonitor | 1s | `netstat -ibn` | RX/TX rates, MTU, error counts, link flap events |
| SpeedTestMonitor | on-demand | `networkQuality` | download/upload throughput, results history |

## Connectors

| Connector | Transport | What It Watches |
|-----------|-----------|-----------------|
| CM3000Connector | SSH → Redis | Cable modem: downstream/upstream SNR, power, uncorrectable codewords, T3/T4 timeouts |
| FirewallaConnector | SSH → Redis | Firewall: WAN status, active alarms, top talkers, blocked domains, device list |
| OrbiConnector | SOAP (LAN) | Mesh router: WAN status, per-satellite backhaul band/clients, firmware version |
| NighthawkConnector | LAN API | Secondary router/AP: status and basic metrics |

Credentials read from `~/.env` (`CM3000_ADMIN_PASS`, `FIREWALLA_SSH_PASS`). No 1Password dependency.

## Views

- `ContentView.swift` — `NavigationSplitView`. Sidebar: Overview, Ping, DNS, Traceroute, Incidents, Speed Test, Stack Health, Timeline, Topology, Connectors (Firewalla / Orbi / CM3000 / Nighthawk tabs). `CommandPaletteView` (⌘K) for quick navigation.
- `OverviewView.swift` — live gateway RTT, Wi-Fi (SSID, RSSI, SNR, retry rate), interface stats, bandwidth sparklines, link flap badge, Claude companion card (hint keyed to worst current signal), topology minimap.
- `PingView.swift` — per-target RTT history chart, sparkline sidebar rows, p50/p95/p99 stat cards, jitter/min/max.
- `DNSView.swift` — per-domain query times, multi-resolver proportional bar chart (`resolverTimes`).
- `TracerouteView.swift` — per-hop RTT bars, ASN + city/country from geo cache, auto-cycling.
- `TimelineView.swift` — 15-minute uptime swimlane per target (green/red/dark).
- `TopologyView.swift` — node-link diagram: CM3000 → Firewalla → Orbi → satellites → clients; edges colored by health.
- `StackHealthView.swift` — cross-layer diagnosis table (physical→app), Claude companion card with hint keyed to health score + root-cause layer.
- `IncidentsView.swift` — incident list with bundle path, open-in-Finder button.
- `FirewallaIntelligenceView.swift` — live flows (top talkers), active alarms, top destinations; device pause/resume/block actions.
- `OrbiIntelligenceView.swift` — per-satellite backhaul detail, client count, online status.
- `CM3000IntelligenceView.swift` — per-channel SNR, power, and uncorrectable codeword table.
- `SpeedTestView.swift` — on-demand speed test trigger, results history chart.
- `MenuBarStatusView.swift` — `NSStatusItem` popover with live download/upload rates, gateway RTT, Wi-Fi SSID + RSSI, per-target ping glance.
- `ClaudeCompanionCard.swift` — shared component: `ClaudeCompanionCard` (full card) + `ClaudeCompanionButton` (compact header variant). Copies a formatted network-context prompt to clipboard and deep-links to `claude://` with `https://claude.ai/new` fallback.
- `PreferencesView.swift` — editable ping/DNS/traceroute targets, thresholds, poll interval, bandwidth budget, webhook URL, mobile API toggle, storage path. Bulk target import (paste newline-separated IPs/hostnames).

## NetWatchMobile Target

`Sources/NetWatchMobile/` — iOS companion app that connects to the Mac's `NetWatchAPIServer` over LAN.

- `APIClient.swift` / `APIModels.swift` — typed client for `/ping /health /snapshot /events`; `ConnectionState` tracks server reachability
- `NetWatchMobileApp.swift` — entry point; wires `APIClient` into environment
- Views: `MobileOverviewView`, `MobileIncidentsView`, `MobileConnectorsView`, `MobileSettingsView`

Design doc: `NETWATCH_MOBILE_DESIGN.md` in repo root.

## Key Design Decisions

- **Sequential connector polling** — `ConnectorManager.pollAll()` runs connectors one at a time (not `async let` parallel) because CM3000 and Firewalla both use SSH tunnels; simultaneous connections cause auth conflicts.
- **Symlink resolution before writes** — `String.write(to:atomically:true)` creates a temp file then renames; this fails silently when the destination path passes through a symlink. All incident bundle writes call `.resolvingSymlinksInPath()` first.
- **NWListener on `@MainActor`** — the mobile API server moved to `@MainActor`-isolated context to eliminate actor-crossing Swift concurrency warnings that prevented launch.
- **`StackDiagnosis.report()` string formatting** — `String(format: "%-16s", nsstring)` triggers PAC failure on ARM64 (pointer authentication rejects NSString pointer as C string). Uses Swift `.padding(toLength:withPad:startingAt:)` instead.
- **Geo enrichment caching** — traceroute hop IPs are looked up against `ipapi.co` once and cached; RFC-1918 and loopback addresses are short-circuited (no request made).
- **Incident bundle cooldown** — `IncidentManager` gates bundle writes behind a cooldown to avoid flooding `~/network_tests/` on sustained outages.
- **UpdateChecker fires once per launch** — no background timer after the initial check; avoids hammering the GitHub API.

## Known Issues / Tech Debt

- GPG signing must be disabled for non-interactive commits: `git -c commit.gpgsign=false commit`
- `CM3000Connector` + `FirewallaConnector` require SSH keys or password auth to the respective devices; credentials must be in `~/.env`
- `networkQuality` (SpeedTestMonitor) requires macOS 12+ and may be rate-limited by Apple
- Geo enrichment (`ipapi.co`) has a free-tier rate limit; sustained traceroute auto-cycling can exhaust it
- `NetWatchMobile` target requires a device on the same LAN as the Mac running NetWatch (mDNS or manual IP entry)
- `tcpdump` in incident bundles requires root; the app skips it gracefully when permission is denied
