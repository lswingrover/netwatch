# Changelog

All notable changes to NetWatch are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
