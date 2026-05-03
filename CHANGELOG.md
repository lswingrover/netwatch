# Changelog

All notable changes to NetWatch are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.3.1] — 2026-05-03

### Added
- **Firewalla intelligence view** — new sidebar tab surfacing live flows (top talkers by bytes), active alarms, and top network destinations; powered by a Python snapshot script that reads Firewalla's local Redis store over SSH
- **Firewalla device actions** — pause/resume network access and block domains for any device from within the Firewalla tab
- **Bulk target import** — paste a newline-separated list of IPs/hostnames into Preferences to add multiple ping/DNS/traceroute targets at once; includes cross-list add UI (add a host to multiple lists simultaneously)
- **Speed test monitor** — wraps Apple's `networkQuality` tool; on-demand test with results history chart on a dedicated Speed Test tab; wired into sidebar nav and Settings
- **Auto-remediation engine** — DNS failover on repeated ping failure: when a configured target is unreachable, `RemediationEngine` automatically rotates the system DNS resolver to a fallback (Cloudflare/Google) and logs the action to the incident bundle
- **Orbi satellite detail view** — per-satellite panel in the Orbi connector tab showing backhaul band, client count, MAC, and online status; satellite list sourced from `GetAttachDevice2` ConnAPMAC inference
- **Network topology map** — visual node-link diagram in the Overview tab showing the detected topology (CM3000 → Firewalla → Orbi router → satellites → clients); edges colored by health status
- **Menu bar quick stats** — per-app status item shows live download/upload rates, gateway RTT, and a glanceable health indicator without opening the main window
- **Keyboard shortcuts** — `⌘P` pause/resume, `⌘R` speed test, `⌘T` traceroute; documented in Monitor menu

### Fixed
- **Orbi V7 firmware client/satellite parsing** — RBRE960 firmware V7.2.8.2 returns structured `<Device>` XML blocks in `GetAttachDevice2` instead of the legacy pipe/at-delimited format; rewrote parsing with `parseDeviceBlocks` + `fetchRawSOAP`; client count now accurate (14 devices) and satellite detection works via `ConnAPMAC` heuristic (1 satellite detected at `34:98:B5:DD:09:B6`)
- **`NSLocalNetworkUsageDescription` / macOS 14+ local network permission** — added required plist key and `NSBonjourServices` to `support/Info.plist`; `build_app.sh` already copies and re-signs, so permission is stable across binary updates
- **StackHealth local client inference** — improved heuristic no longer mis-classifies Orbi satellite APs as wired clients; mesh backhaul clients excluded from local client count
- **About panel version string** — hardcoded `"1.3.0"` in `NetWatchApp.swift` now reads `"1.3.1"` to match `Info.plist`

### Changed
- `CM3000Connector` updated to remove 1Password UUID lookups; credentials read directly from `~/.env` (`CM3000_ADMIN_PASS`, `FIREWALLA_SSH_PASS`); reduces dependency on `op` CLI and eliminates lookup failures when 1Password is locked
- `CM3000Connector` now exposes per-channel SNR, power, and uncorrectable codeword data for the channel detail table added in Sprint 7
- `ConnectorManager.pollAll()` now polls connectors sequentially (was parallel) to prevent SSH tunnel conflicts between Firewalla and CM3000 scripts
- `build_app.sh` — ad-hoc code signing step now uses `--options runtime` flag for consistency; `NSWorkspace.setIcon` step added to beat Dock icon cache on reinstall
- `Info.plist` `CFBundleVersion` bumped to 5, `CFBundleShortVersionString` bumped to 1.3.1

---

## [1.3.0] — 2026-04-29

### Added
- **RTT percentiles** — p50, p95, and p99 computed over all collected samples; displayed as a third stat row in PingDetailView
- **Multi-resolver DNS comparison** — each DNS query now runs concurrently against System, Cloudflare (1.1.1.1), Google (8.8.8.8), and Quad9 (9.9.9.9); results shown as a proportional bar chart in DNSDetailView
- **Wi-Fi SNR** — signal-to-noise ratio (RSSI − Noise Floor) displayed in Overview Wi-Fi row; green ≥ 25 dB, yellow ≥ 15 dB, red < 15 dB
- **Wi-Fi retry rate** — `agrCtlRetryRate` parsed from `airport -I`; high retries indicate RF interference or range issues
- **Link flap detector** — InterfaceMonitor tracks interface up/down transitions with timestamps; count badge and live log shown in Overview
- **Traceroute geo enrichment** — after each trace, hop IPs are looked up against `ipapi.co` (HTTPS, free, cached); ASN short code and city/country shown in the hops table
- **Timeline view** — new sidebar item showing per-target uptime swimlane for the last 15 minutes; green = success, red = failure, dark = no data; covers both ping and DNS targets
- **`GeoInfo` model** — ASN, city, country; `asnShort` and `location` computed display properties
- **`LinkFlap` model** — timestamped up/down event with UUID identity
- **`p50`/`p95`/`p99` on PingState** — percentile computed properties using integer index interpolation
- **`resolverTimes` on DNSState** — `@Published [String: Double?]` map updated after each multi-resolver query round

### Changed
- `Info.plist` / `NetWatchApp.swift` bumped to 1.3.0 / build 4
- TracerouteDetailView now accepts a `geoCache` parameter and renders ASN + location column

---

## [1.2.0] — 2026-04-29

### Added
- **Auto-update checker** — polls `api.github.com/repos/lswingrover/netwatch/releases/latest` hourly; fires a macOS notification and shows an in-app banner on the Overview tab when a newer version is available; banner includes a direct "View Release" link and a dismiss button
- **`UpdateChecker.swift`** — `@MainActor ObservableObject` with semver integer comparison, system notification delivery, and hourly `Timer`-based polling

### Changed
- `NetWatchApp.swift` bumped version string to 1.2.0
- `build_app.sh` — added `killall Dock` after `lsregister` to force icon cache refresh on reinstall
- Ping, DNS, and Traceroute target lists are now fully editable inline (add, delete, reorder) in Preferences

---

## [1.1.0] — 2026-04-29

### Added
- **Menu bar extra** — color-coded status icon (green/yellow/red) with a popover showing live download/upload rates, gateway RTT, Wi-Fi SSID + RSSI, and a per-target ping quick-glance
- **System notifications** — macOS notification fires on each new incident via `UNUserNotificationCenter`; requests permission on first launch
- **Wi-Fi forensics** — SSID, RSSI (dBm), noise floor, channel, MCS index, and last Tx rate sampled every 5s via `airport -I`; displayed in Overview when on Wi-Fi
- **Bandwidth history chart** — rolling 2-minute area chart of download and upload rates on the Overview tab
- **Forensic ping stats** — jitter (population σ of last 20 RTTs), min RTT, max RTT, and sample count added to PingDetailView stat cards
- **Expanded Overview ping table** — columns for Min, Max, and Jitter alongside existing Avg/Loss/Status
- **Interface forensics row** — RX/TX error counts, MTU, and RX packets/s on the Overview tab
- **RTT sparklines in ping sidebar** — last 15 successful RTTs rendered as a color-coded mini sparkline in each list row
- **Config export/import** — serialize all settings to a pretty-printed JSON file; import on another machine via Preferences → Storage
- **`recentRTTs` on PingState** — computed property returning last 15 successful RTT values for sparkline rendering
- **`jitter`, `minRTT`, `maxRTT` on PingState** — computed forensic properties
- **`BandwidthSample` model** — timestamped RX/TX byte-rate snapshot for history charting
- **`bandwidthHistory` on InterfaceMonitor** — rolling 120-sample buffer (≈2 min at 1s interval)
- **MTU parsing** — extracted from `netstat -ibn` col[1] and surfaced in Overview
- **README.md** — full architecture diagram, build instructions, feature list, roadmap

### Fixed
- **Sidebar navigation broken** — `List` items were missing `.tag(item)`, so selection state was never written; clicking had no effect
- **`$0` ambiguity in nested closures** — `forEach { Task { await $0.stop() } }` was ambiguous; changed to explicit `m in` parameter
- **`List` selection requires `Hashable`** — PingView, DNSView, and IncidentsView all changed from object selection to ID-based (`String?` / `UUID?`) selection with computed lookup
- **`onChange(of:perform:)` deprecation** — updated to two-parameter form
- **DNSView type-checker timeout** — extracted inner `HStack` into `DNSResultRow` struct to help Swift's type checker

### Changed
- `NetWatchApp.swift` bumped version string to 1.1.0
- Icon arc angles corrected — wifi arcs now point upward (startAngle ~36°, endAngle ~144°, arc center lowered to 30% of icon height)

---

## [1.0.0] — 2026-04-28

### Added
- Initial release — full rewrite of bash `monitor_lazy.sh` as a native SwiftUI macOS app
- Ping monitoring with rolling 100-sample RTT history, success rate, and trend indicator
- DNS monitoring with `dig`-based query time tracking per domain
- Interface stats via `netstat -ibn` — RX/TX rates, packet counts, error counters
- Gateway RTT history sparkline
- Traceroute — auto-cycling with per-hop RTT bar chart
- Incident bundler with cooldown — writes `incident.txt` + ISP tier-2 ticket draft
- NavigationSplitView UI with Overview, Ping, DNS, Traceroute, and Incidents tabs
- Preferences — editable targets, thresholds, storage path
- `build_app.sh` — one-shot build → sign → install → launch script
- `make_icon.swift` — programmatic app icon via AppKit + iconutil
- `support/Info.plist` — proper app bundle metadata (moved outside SPM resources to avoid forbidden-resource error)
- Ad-hoc code signing and LaunchServices registration for Dock presence
