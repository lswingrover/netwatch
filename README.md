# NetWatch

A native macOS network monitoring dashboard. Tracks ping latency, DNS health, interface throughput, traceroutes, and Wi-Fi signal — with automatic incident bundling and ISP escalation drafts.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## Features

- **Live ping monitoring** — configurable targets, 1-second intervals, rolling RTT sparklines per target
- **DNS health** — `dig`-based queries with response time and status tracking (NOERROR / SERVFAIL / etc.)
- **Interface stats** — RX/TX bytes/s, packets/s, error counts, MTU, TCP session count
- **Bandwidth history** — rolling 2-minute area chart of download and upload rates
- **Wi-Fi forensics** — SSID, RSSI (dBm), noise floor, MCS index, last Tx rate via `airport`
- **Gateway RTT** — dedicated gateway ping history sparkline
- **Traceroute** — auto-cycling per-target traceroutes with per-hop RTT chart
- **Incident bundling** — cooldown-gated incident detector writes `incident.txt` + ISP tier-2 ticket draft + per-target ping logs
- **System notifications** — macOS notifications fire on each new incident
- **Menu bar presence** — color-coded status icon (green/yellow/red) with a popover showing live stats
- **Forensic stats** — per-target jitter, min/max RTT, packet loss%, sample count
- **Configurable targets** — add/remove/reorder ping IPs, DNS domains, and traceroute targets from Preferences
- **Config export/import** — serialize all settings to JSON; import on another machine

---

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ (for building from source)

---

## Build & Install

### One-shot script
```bash
cd ~/Developer/NetWatch      # or wherever you cloned it
bash build_app.sh
```

Builds a release binary, generates the app icon, assembles `NetWatch.app`, ad-hoc signs it, installs to `/Applications`, registers with Launch Services, and opens the app.

**Options:**
```
--debug       Build debug instead of release
--no-install  Stop after assembly; app lands at /tmp/NetWatch.app
```

### Dock
Right-click the NetWatch icon in the Dock while it's running → **Options → Keep in Dock**.  
Or drag `/Applications/NetWatch.app` into your Dock manually.

---

## Configuration

Open **NetWatch → Settings** (⌘,) or the **Monitor** menu.

| Tab | What you can change |
|-----|---------------------|
| **Targets** | Ping hosts (IP or hostname + optional label), DNS domains, traceroute targets |
| **Thresholds** | Ping/DNS intervals, consecutive-fail counts before incident, incident cooldown |
| **Storage** | Base directory for logs/incidents, export/import JSON config |

Default ping targets: Cloudflare (1.1.1.1), Google (8.8.8.8), Quad9 (9.9.9.9), OpenDNS (208.67.222.222), two Spectrum gateway IPs.

---

## How incidents work

Every 5 seconds, NetWatch checks for:
- **PING_MULTI_FAILURE** — ≥2 targets consecutively failing (likely upstream)
- **PING_FAILURE** — any single target failing the configured consecutive threshold
- **DNS_FAILURE** — any DNS domain failing its threshold

When triggered (subject to cooldown), it writes a bundle to `~/network_tests/incidents/incident_<timestamp>/`:
```
incident.txt          — human-readable summary with ping/DNS/traceroute state
tier2_ticket.txt      — ISP escalation draft, ready to paste
ping_<host>.txt       — last 50 ping results per target
```

A macOS notification fires immediately. Incidents are visible in the **Incidents** tab.

---

## Architecture

```
NetWatchApp.swift              @main App — WindowGroup + MenuBarExtra + Settings scenes
Models/Models.swift            All data structs and ObservableObjects
Monitors/
  ProcessRunner.swift          Async Foundation.Process wrapper with timeout watchdog
  PingMonitor.swift            actor — runs /sbin/ping, updates PingState
  DNSMonitor.swift             actor — runs /usr/bin/dig, updates DNSState
  InterfaceMonitor.swift       @MainActor — netstat/ifconfig/airport sampling
  TracerouteMonitor.swift      @MainActor — cyclic traceroute runner
  IncidentManager.swift        @MainActor — cooldown-gated incident bundler + notifications
  NetworkMonitorService.swift  @MainActor — orchestrator, owns all monitors
Views/
  ContentView.swift            NavigationSplitView sidebar + detail router
  OverviewView.swift           Status banner, stat cards, sparklines, summary tables
  PingView.swift               Per-target RTT charts + results log
  DNSView.swift                Per-domain query time charts + results log
  TracerouteView.swift         Per-target hop table + RTT bar chart
  IncidentsView.swift          Incident list + bundle reader + clipboard copy
  MenuBarStatusView.swift      Menu bar extra popover
  PreferencesView.swift        Settings tabs (Targets / Thresholds / Storage)
support/Info.plist             App bundle metadata
make_icon.swift                Swift script — generates AppIcon.icns via AppKit + iconutil
build_app.sh                   One-shot build + sign + install script
```

---

## Roadmap

- [ ] Persistent history — SQLite store for multi-day RTT/DNS trend analysis
- [ ] Auto-start on login — `SMAppService` registration toggle in Preferences
- [ ] Packet loss heatmap — calendar-style hourly loss grid
- [ ] Alert profiles — separate thresholds per target (e.g. tighter for gateway)
- [ ] Menubar sparkline — tiny inline chart in the menu bar item itself

---

## License

MIT — see [LICENSE](LICENSE).
