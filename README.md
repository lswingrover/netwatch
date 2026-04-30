# NetWatch

A native macOS network monitoring dashboard built entirely in Swift and SwiftUI. Tracks ping latency, DNS health, interface throughput, traceroutes, and Wi-Fi signal quality — with automatic incident bundling and ISP escalation drafts.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## Why this exists

Commercial tools like PingPlotter cost money and run in the browser or via Electron. Little Snitch and similar tools care about *what* is talking, not *how well* it's talking. macOS's built-in Network Utility was [removed in Monterey](https://support.apple.com/en-us/HT213790). Nothing free and native gives you persistent per-target RTT history, multi-resolver DNS comparison, interface-level throughput, and automatic incident logging in one window.

NetWatch fills that gap. It's a 2,000-line Swift program that shells out to `ping`, `dig`, `traceroute`, `netstat`, `ifconfig`, and `airport` — the same UNIX tools you'd run manually — and presents the results as a live dashboard with charts, percentile stats, and incident bundles ready to paste into a support ticket.

**Typical use cases:**
- You suspect your ISP is degrading during peak hours but need timestamps and packet loss numbers before calling
- You're on a video call and it drops — you want to know whether it was your Wi-Fi, your gateway, or upstream
- You're a developer whose work requires a reliable connection and you want a persistent canary running in the menu bar
- You're troubleshooting a home network and want real data instead of vibes

---

## Features

### Ping monitoring

Polls each configured target once per second using `/sbin/ping -c 1 -W 2000`. Per-target state tracks:

- **Last / Avg RTT** — instantaneous and rolling mean (ms)
- **Min / Max RTT** — floor and ceiling across all samples
- **Jitter** — mean absolute deviation of RTT samples: `Σ|RTTᵢ - mean| / n`. Low jitter (< 5 ms) means your connection is stable even if latency is moderate. High jitter (> 20 ms) on video calls causes audio stuttering and frame drops even if average RTT looks fine.
- **Packet loss %** — `(failures / total) * 100`. Even 1–2% packet loss causes TCP retransmissions and noticeable quality degradation on video.
- **Percentiles (p50, p95, p99)** — The median (p50) is more meaningful than average because a handful of 500 ms spikes can make a 15 ms average look like 30 ms. p95 tells you the worst RTT 95% of pings stay under — the number your VoIP app actually experiences during normal use. p99 is your tail latency: what the unlucky ping gets.
- **Trend** — direction inferred from slope of recent samples (↑ degrading / ↓ improving / → stable)
- **Rolling sparkline** — last 20 samples in the sidebar row for at-a-glance history

**Why multiple targets?** Pinging only 8.8.8.8 tells you whether the internet is reachable, but not *where* it breaks. NetWatch defaults to Cloudflare (1.1.1.1), Google (8.8.8.8), Quad9 (9.9.9.9), OpenDNS (208.67.222.222), and — critically — your local gateway IPs. If 1.1.1.1 is failing but your gateway is fine, the problem is upstream. If your gateway is also failing, the problem is your LAN/router. If everything is failing, your NIC or cable is the suspect.

---

### DNS health

Runs `/usr/bin/dig @<resolver> <domain> +time=3 +tries=1` per domain per interval, then records query time and the RCODE (NOERROR, SERVFAIL, NXDOMAIN, TIMEOUT, etc.).

**Multi-resolver comparison** runs the same query simultaneously against your system resolver, Cloudflare (1.1.1.1), Google (8.8.8.8), and Quad9 (9.9.9.9) and renders proportional timing bars. This surfaces two common problems:

1. **ISP DNS hijacking** — your system resolver returns faster than public resolvers because it's caching aggressively and potentially intercepting NXDOMAIN for ad injection. Or slower because it's dog slow and you should switch.
2. **DNS-based throttling** — some ISPs selectively slow-walk or SERVFAIL queries for specific domains. If cloudflare.com resolves in 8 ms via 1.1.1.1 but takes 400 ms via your system resolver, that's a signal.

DNS failures often precede ping failures in incident timelines because the OS DNS cache masks temporary outages — until it doesn't.

---

### Interface stats

Samples `/usr/sbin/netstat -ib` and `/sbin/ifconfig` on a configurable interval to compute per-interface:

- **RX/TX bytes/s and packets/s** — delta between consecutive netstat snapshots
- **Error counts** — input and output error increments (non-zero values here indicate hardware or driver problems, not just congestion)
- **MTU** — Maximum Transmission Unit. Standard Ethernet is 1500 bytes. Jumbo frames are 9000. If your MTU is unexpectedly low (< 1500), some middlebox is fragmenting your traffic, which adds latency and CPU load.
- **TCP session count** — number of active connections via `netstat -an | grep ESTABLISHED`
- **Wi-Fi metrics** — SSID, BSSID, RSSI (dBm), noise floor (dBm), SNR (dB), MCS index, last Tx rate (Mbps), channel

**On Wi-Fi metrics specifically:**

- **RSSI** is signal strength. -50 dBm is excellent, -70 dBm is marginal, -80 dBm is poor. This is logarithmic — every 10 dB is a 10x power difference.
- **Noise floor** is the background RF noise level, typically -90 to -95 dBm in a quiet environment. Higher (closer to 0) means RF interference.
- **SNR = RSSI − noise floor.** This is what actually matters for link quality. An SNR > 25 dB is good. Below 10 dB and you'll see retransmissions. The OS reports RSSI but hides noise floor in most UIs; NetWatch surfaces both.
- **MCS index** (Modulation and Coding Scheme) determines the encoding strategy. Higher MCS = higher throughput at the cost of requiring better signal quality. MCS 0 = BPSK 1/2 (robust, slow). MCS 11 (Wi-Fi 6) or MCS 9 (Wi-Fi 5) = highest throughput modes. If your MCS index is low despite close physical proximity to the AP, RF interference or a noisy channel is likely.
- **Last Tx rate** is the actual negotiated PHY rate in Mbps. 802.11ac on a clear channel at close range should be 400–867 Mbps. If you're getting 54 Mbps, you're probably on legacy 802.11g compatibility mode.

---

### Traceroute

Runs `/usr/sbin/traceroute -n -q 1 -w 2 <target>` on a configurable cycle (default: each target every 5 minutes). Per-hop results show:

- IP address and resolved hostname
- RTT
- Geographic info (country/city) via ip-api.com — useful for verifying whether traffic is taking an unexpected international path
- A bar chart of per-hop RTTs to visualize where latency accumulates

**Reading a traceroute:** Latency should increase monotonically hop-by-hop. A hop with *lower* RTT than the previous hop means that router is de-prioritizing ICMP responses (common — not a problem). A sudden large jump (e.g., hop 8 adds 80 ms) is where congestion or a long-haul fiber segment lives. The last hop is your destination; if it's unreachable but earlier hops respond, the destination is filtering ICMP — not actually down.

---

### Incident bundling

Every 5 seconds, the `IncidentManager` evaluates:

```
PING_MULTI_FAILURE  ≥2 targets consecutively failing
PING_FAILURE        any single target exceeding consecutive-fail threshold  
DNS_FAILURE         any DNS domain exceeding consecutive-fail threshold
```

A cooldown period (default: 5 minutes) prevents duplicate incidents from the same event. When triggered, it writes a bundle to `~/network_tests/incidents/incident_<ISO8601_timestamp>/`:

```
incident.txt        Human-readable summary: all target states, Wi-Fi info, interface stats
tier2_ticket.txt    ISP escalation draft with timestamps, affected targets, sample data
ping_<host>.txt     Last 50 ping results per target (timestamp, RTT, success/fail)
```

**Why this is useful:** When your internet goes down, you're usually busy trying to fix it or work around it. The last thing you do is open a terminal and start logging. By the time you call your ISP, you have nothing but "it was down for a while." NetWatch logs retroactively — the incident bundle captures what was already in memory at the moment the threshold was crossed. The `tier2_ticket.txt` is formatted to be pasted directly into an ISP's Tier 2 support form: timestamps, packet loss percentages, affected hosts, and traceroute output.

---

### Menu bar presence

A `MenuBarExtra` shows a color-coded dot (green/yellow/red) driven by `overallStatus`:

- **Green** — all targets healthy
- **Yellow** — degraded (some packet loss or elevated RTT, but not down)
- **Red** — critical (multi-target failure or incident active)

The popover shows live stats without switching windows — useful when you want a persistent canary in the corner of your screen.

---

## Architecture

```
NetWatchApp.swift              @main — WindowGroup + MenuBarExtra + Settings scenes
Models/Models.swift            Data structs: PingTarget, PingResult, PingState,
                               DNSTarget, DNSResult, DNSState, InterfaceSnapshot,
                               TracerouteResult, Incident, AppSettings
Monitors/
  ProcessRunner.swift          Async Foundation.Process wrapper with timeout watchdog
  PingMonitor.swift            Swift actor — runs /sbin/ping, updates PingState
  DNSMonitor.swift             Swift actor — runs /usr/bin/dig, updates DNSState
  InterfaceMonitor.swift       @MainActor — netstat/ifconfig/airport sampling loop
  TracerouteMonitor.swift      @MainActor — cyclic traceroute runner
  IncidentManager.swift        @MainActor — cooldown-gated incident bundler + notifications
  NetworkMonitorService.swift  @MainActor — orchestrator, owns all monitors + settings
Views/
  ContentView.swift            NavigationSplitView sidebar + detail router
  OverviewView.swift           Status banner, stat cards, sparklines, summary tables
  PingView.swift               Per-target RTT charts + results log
  DNSView.swift                Per-domain query time charts + multi-resolver comparison
  TracerouteView.swift         Per-target hop table + RTT bar chart
  IncidentsView.swift          Incident list + bundle reader + clipboard copy
  MenuBarStatusView.swift      Menu bar extra popover
  PreferencesView.swift        Settings tabs (Targets / Thresholds / Storage)
support/Info.plist             App bundle metadata (CFBundleVersion, NSPrincipalClass, etc.)
make_icon.swift                Standalone Swift script — renders AppIcon.icns via AppKit + iconutil
build_app.sh                   One-shot build + sign + install + cache-nuke script
```

### Design decisions worth knowing about

**Why Swift actors for ping and DNS?** Each target polls on its own 1-second timer. With six ping targets and six DNS domains running concurrently, you have twelve background tasks firing simultaneously. Swift actors provide data-race safety for free — `PingState` and `DNSState` are `@Published ObservableObject`s accessed from the main actor for UI, but mutated only inside the actor that owns them. No locks, no queues, no crashes.

**Why shell out to `ping` and `dig` instead of using raw sockets?** Raw ICMP requires a root-privileged socket or a special entitlement (`com.apple.security.network.client` + `com.apple.developer.networking.custom-protocol`). Shipping a sandboxed app with raw socket access is painful to notarize. `/sbin/ping` runs setuid-root, so the OS handles privilege elevation transparently. `dig` is universally available and its output format is stable. The tradeoff is process-launch overhead (~15 ms per invocation) — acceptable for 1-second polling intervals, not for anything tighter.

**Why `@MainActor` for `NetworkMonitorService` and `IncidentManager`?** Both own `@Published` state that drives SwiftUI views. SwiftUI requires all `@Published` mutations to happen on the main thread. Marking the whole class `@MainActor` is cleaner than sprinkling `DispatchQueue.main.async` everywhere and makes accidental off-thread mutation a compile error.

**Why `HSplitView` instead of `NavigationSplitView` for the per-view list/detail splits?** The outer chrome is a `NavigationSplitView` (sidebar + detail column). Inside the detail column, Ping Targets, DNS, and Traceroute each have a secondary list/detail layout. A nested `NavigationSplitView` doesn't behave well inside an existing split — it tries to own the column model and fights with the outer split. `HSplitView` is the AppKit-backed primitive that just makes a horizontal resizable split without column opinions.

**Why ad-hoc signing instead of Developer ID?** NetWatch is a personal tool. Apple's notarization requirement applies to apps *distributed outside the App Store* to other machines. For local use, ad-hoc signing (`codesign --sign -`) satisfies Gatekeeper's "this binary hasn't been tampered with" check without needing a paid developer account or Apple's notarization servers. If you want to distribute it, swap `--sign -` for `--sign "Developer ID Application: <you>"` and add `xcrun notarytool` to the build script.

**Why a standalone `make_icon.swift` script instead of an asset catalog?** SPM (Swift Package Manager) supports asset catalogs via `Bundle.module`, but the `.xcassets` format requires Xcode to generate the catalog — it's not hand-editable JSON. `make_icon.swift` generates all icon sizes programmatically using AppKit's `NSBezierPath` and `CGContext`, then calls `iconutil` to produce the `.icns`. Every pixel is reproducible from code; no binary blobs in the repo.

---

## Install

> **This repo is source code only — there is no pre-built download.** You build it yourself in about 30 seconds. The build script handles everything including icon generation, signing, and installing to `/Applications`.

### Prerequisites

- **macOS 14 Sonoma or later**
- **Xcode Command Line Tools** (free, ~2 GB). If you don't have them:
  ```bash
  xcode-select --install
  ```
  A dialog will appear — click Install and wait. Skip this step if you already have Xcode installed.

You do **not** need a paid Apple Developer account. You do **not** need Xcode itself (the command-line tools are enough).

### Build & Install

```bash
git clone https://github.com/lswingrover/netwatch.git
cd netwatch
bash build_app.sh
```

That's it. The script compiles the Swift source, generates the app icon, assembles `NetWatch.app`, ad-hoc signs it, installs it to `/Applications`, and opens it. Total time: ~30 seconds on Apple Silicon, ~60 seconds on Intel.

**Options:**
```
--debug       Build debug binary (larger, slower, includes DWARF symbols)
--no-install  Stop after assembly; app lands at /tmp/NetWatch.app
```

### First launch — Gatekeeper warning

Because NetWatch is ad-hoc signed (not notarized by Apple), macOS will block the very first launch with:

> *"NetWatch cannot be opened because it is from an unidentified developer."*

**Fix — one of two options:**

**Option A (GUI):** In Finder, navigate to `/Applications`, right-click `NetWatch.app` → **Open** → click **Open** in the confirmation dialog. You'll only need to do this once; macOS remembers the exception.

**Option B (Terminal):**
```bash
xattr -dr com.apple.quarantine /Applications/NetWatch.app
open /Applications/NetWatch.app
```

This removes the quarantine flag that macOS adds to downloaded files. It's the same operation Option A performs under the hood.

> **Why is it safe?** The ad-hoc signature (`codesign --sign -`) proves the binary hasn't been tampered with since it was built on your machine. It just doesn't have Apple's notarization stamp, which is only required for distributing to other people's machines.

### Add to Dock

Right-click the NetWatch icon in the Dock while it's running → **Options → Keep in Dock**.  
Or drag `/Applications/NetWatch.app` into your Dock manually.

### What the build script does (step by step)

```
1. swift build -c release          Compiles all Swift sources → .build/release/NetWatch
2. swift make_icon.swift           Renders AppIcon PNGs at 16–1024px → iconutil → AppIcon.icns
3. Assemble /tmp/NetWatch.app      MacOS/ binary + Resources/ bundle + Info.plist
4. codesign --sign - --deep        Ad-hoc signature covering all Mach-O binaries in the bundle
5. cp -R to /Applications          Replaces any existing installation
6. lsregister -kill -r             Rebuilds the full LaunchServices database (forces icon refresh)
7. rm icon caches                  Deletes com.apple.iconservices.store + dock.iconcache
8. killall Finder && killall Dock  Forces both to reload from the rebuilt LS database
9. open /Applications/NetWatch.app Launches the new version
```

---

## Configuration

Open **NetWatch → Settings** (⌘,) or the **Monitor** menu.

| Tab | What you can change |
|-----|---------------------|
| **Targets** | Ping hosts (IP or hostname + optional label), DNS domains, traceroute targets |
| **Thresholds** | Ping/DNS intervals, consecutive-fail count before incident fires, incident cooldown |
| **Storage** | Base directory for logs/incidents, export/import JSON config |

Default ping targets: Cloudflare (1.1.1.1), Google (8.8.8.8), Quad9 (9.9.9.9), OpenDNS (208.67.222.222), plus two Spectrum gateway IPs. Edit these to match your actual gateway (check `netstat -rn | grep default`) and whatever external hosts matter to you.

---

## Reading the stats

| Metric | Good | Watch | Bad |
|--------|------|-------|-----|
| RTT (broadband) | < 20 ms | 20–80 ms | > 100 ms |
| RTT (satellite) | < 40 ms | 40–100 ms | > 600 ms |
| Jitter | < 5 ms | 5–20 ms | > 30 ms |
| Packet loss | 0% | < 1% | ≥ 1% |
| p95 – p50 spread | < 10 ms | 10–40 ms | > 50 ms |
| DNS query time | < 30 ms | 30–100 ms | > 200 ms |
| Wi-Fi SNR | > 25 dB | 15–25 dB | < 15 dB |
| Wi-Fi RSSI | > −65 dBm | −65 to −75 dBm | < −80 dBm |

A large **p95 − p50 spread** with low average loss usually means bufferbloat: your router's queue is absorbing packets rather than dropping them, introducing variable delay. The fix is typically enabling CAKE or fq_codel on your router's QoS settings.

---

## Requirements

- macOS 14 Sonoma or later (uses `Charts` framework introduced in macOS 13, plus `MenuBarExtra` from macOS 13)
- Xcode 15 / Swift 5.9 or later (for building from source)
- No entitlements, no App Store, no notarization required for local use

---

## Roadmap

- [ ] **Persistent history** — SQLite store via GRDB for multi-day RTT/DNS trend analysis and session replay
- [ ] **Auto-start on login** — `SMAppService` registration toggle in Preferences
- [ ] **Packet loss heatmap** — calendar-style hourly loss grid (like GitHub's contribution graph, but for your ISP's failures)
- [ ] **Alert profiles** — separate thresholds per target (e.g., tighter tolerance for your gateway vs. a remote CDN)
- [ ] **Menubar sparkline** — tiny inline RTT chart rendered directly in the menu bar item
- [ ] **DSCP/QoS tagging** — mark probe packets with CS1 vs EF DSCP values to test whether your ISP differentiates traffic classes

---

## License

MIT — see [LICENSE](LICENSE).
