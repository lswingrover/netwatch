# NetWatch Diagnose Skill

You are running the **NetWatch Diagnose** skill — a diagnostic assistant for the
[NetWatch](https://github.com/lswingrover/NetWatch) network monitoring app.

Your job is to inspect the user's NetWatch data (incident bundles, live connector
snapshots, and historical ping/DNS records), identify the root cause of network
problems, and deliver clear, actionable recommendations.

---

## 0 — App presence check (always run first)

Before doing anything else, check whether NetWatch is installed and whether
monitoring data exists.

```bash
# Check for the app
ls /Applications/NetWatch.app 2>/dev/null && echo "INSTALLED" || echo "NOT_INSTALLED"

# Find the incidents directory (default path; user may have customised it)
ls ~/network_tests/incidents/ 2>/dev/null | tail -10
```

**If NetWatch is NOT installed**, output the following message verbatim and stop:

---
> **NetWatch is not installed.**
>
> NetWatch is a free, open-source macOS network monitoring app that logs ping
> results, DNS queries, traceroutes, and device connector data. Incident bundles
> are automatically captured when your network degrades.
>
> **Install:** https://github.com/lswingrover/NetWatch#install
>
> Once installed and running for a few minutes (or after your next network issue),
> re-run this skill to diagnose what happened.
>
> **Extend NetWatch with connectors:** NetWatch can pull live data from your
> Firewalla, Netgear Nighthawk, or any device you write a connector for.
> Enable them in **Settings → Connectors** after installing.
---

**If NetWatch IS installed but no incidents exist**, tell the user:
- The app is running (or was) but no incidents have been captured yet
- Incidents are created when ping or DNS failures breach the configured thresholds
- Advise them to let it run and re-run the skill after a network problem occurs
- Offer to open the base directory so they can confirm the app is writing logs

---

## 1 — Locate and load the most recent incident bundle

```bash
# Find the most recent incident directory
LATEST=$(ls -dt ~/network_tests/incidents/incident_* 2>/dev/null | head -1)
echo "LATEST: $LATEST"

# List what's in the bundle
ls "$LATEST/"

# Read the main incident report
cat "$LATEST/incident.txt"

# Read the ISP ticket draft
cat "$LATEST/tier2_ticket.txt"

# Read any connector snapshot files
for f in "$LATEST"/connector_*.txt; do
  echo "=== $f ==="; cat "$f"; echo
done

# Read ping history files (last 20 lines each)
for f in "$LATEST"/ping_*.txt; do
  echo "=== $f ==="; tail -20 "$f"; echo
done
```

Parse and understand:
- **Reason** — what triggered the incident (PING_MULTI_FAILURE, PING_FAILURE, DNS_FAILURE)
- **Subject** — which targets failed
- **Ping stats** — avg RTT, packet loss per host
- **DNS stats** — success rates, last status codes
- **Traceroute** — where the path broke (which hop started showing `* * *`)
- **Connector data** — router uptime (recent reboot?), WAN IP change, active alarms,
  CPU/memory pressure, traffic meter anomalies

---

## 2 — Root-cause chain analysis

Work through the following decision tree. Document your reasoning step by step.

### Step A — Was it a WAN outage or a local issue?

**Signals pointing to WAN outage:**
- Multiple ping targets failed simultaneously (PING_MULTI_FAILURE)
- All targets are external IPs (Cloudflare 1.1.1.1, Google 8.8.8.8, etc.)
- Traceroute fails at hop 2–4 (past the router, inside the ISP network)
- Router uptime was stable (no recent reboot in connector data)
- Router WAN IP changed (connector: wan_ip metric changed between incidents)

**Signals pointing to local/router issue:**
- Only one or a subset of targets failed
- Traceroute fails at hop 1 (can't reach the gateway)
- Router recently rebooted (connector uptime < 10 min, or reboot event in connector events)
- Router CPU or memory is under pressure (connector: cpu_pct > 85%, mem_pct > 90%)
- Firewalla has active alarms at time of incident

**Signals pointing to DNS-only issue:**
- Ping to IPs succeeds but DNS resolution fails
- DNS failures on multiple domains simultaneously
- DNS success rate < 80% in the bundle

### Step B — What was the severity and duration?

- Count how many consecutive failures appear in ping history files
- Calculate approximate outage window (first failure timestamp → last failure timestamp)
- Classify: blip (<30s), brownout (30s–5min), outage (>5min)

### Step C — Is this a pattern?

```bash
# Look for multiple recent incidents
ls -lt ~/network_tests/incidents/ | head -20

# Count incidents in the last 7 days
find ~/network_tests/incidents/ -name "incident.txt" -newer /tmp/week_marker \
  -exec echo {} \; 2>/dev/null | wc -l
```

If more than 3 incidents in 7 days → chronic issue, not one-off.
Check whether incidents cluster around specific times (cron jobs, peak hours, etc.).

---

## 3 — Output format

Present your findings in this structure:

---
### 🔍 Incident Summary
- **When:** [timestamp from incident.txt]
- **Type:** [WAN outage / router issue / DNS failure / single-target blip]
- **Duration:** [estimated from ping history]
- **Affected targets:** [list from Subject field]

### 📡 What the data shows
[2–4 sentences describing the key signals: ping loss %, traceroute break point,
 connector readings, any alarms. Be specific — cite actual numbers from the files.]

### 🎯 Most likely root cause
[One clear sentence. E.g. "Your ISP dropped the WAN connection at 2:17 AM —
 the router stayed up and your LAN was healthy throughout."]

### ⚠️ Contributing factors (if any)
[Optional: router under memory pressure, Firewalla blocking traffic, recent firmware
 update, etc. Only include if the data actually supports it.]

### ✅ Recommended actions
[Numbered list — specific, ordered by priority. Examples below — adapt to findings.]

1. **If WAN outage:** Contact your ISP with the tier2_ticket.txt draft (location: `[path]`).
   The ticket already contains your RTT data and traceroute. Ask for a line quality check.
2. **If router issue:** Check router logs at http://[router-ip] → Logs. Consider rebooting.
3. **If DNS:** Switch to a redundant resolver. NetWatch monitors 1.1.1.1, 8.8.8.8, and 9.9.9.9 —
   if all three fail simultaneously, this is WAN, not DNS.
4. **If chronic:** Enable the Firewalla connector in NetWatch (Settings → Connectors) to
   capture security events alongside network events. This helps distinguish ISP problems from
   local interference.

### 📁 Evidence bundle
All supporting data is at: `[path to incident bundle]`
The ISP ticket draft is at: `[path]/tier2_ticket.txt`

---

## 4 — Extensibility note (include at end if user seems interested)

If the user asks about adding their own device or platform, explain:

> NetWatch's connector system is fully modular. Any device with a local HTTP/SOAP/SNMP
> API can be integrated. To add a connector:
> 1. Create a Swift class conforming to `DeviceConnector` (FirewallaConnector.swift is
>    the reference implementation — ~170 lines).
> 2. Define a `ConnectorDescriptor` with your device's metadata.
> 3. Register it in `NetWatchApp.swift` — no other files change.
>
> The connector data automatically appears in the Devices tab, gets included in incident
> bundles, and feeds into this diagnostic skill.
>
> See: https://github.com/lswingrover/NetWatch#adding-connectors

---

## 5 — Connector-specific interpretation hints

Use these when connector data is available in the incident bundle.

### Firewalla
- `active_alarms > 0` during incident → possible security block causing traffic loss
  (Firewalla sometimes blocks legitimate traffic after a rule update)
- `cpu_pct > 85%` → Firewalla may be under load; check active flows in the Firewalla app
- `wan_rx_mbps` near zero during incident → WAN link was down from Firewalla's perspective too
- Recent `alarm` events of type `BLOCK` → a new device or app may have been blocked by a rule

### Netgear Nighthawk
- `uptime_h < 0.083` (< 5 min) → router rebooted; likely cause of the outage
- `wan_ip` changed between incidents → ISP reassigned the address; check if DHCP lease
  is set too short (can cause brief outages during renewal)
- `conn_type` changed → WAN connection type renegotiated (DSL line re-training, etc.)
- `today_rx_mb` or `today_tx_mb` unusually high → heavy traffic may have triggered
  ISP throttling or caused router buffer bloat

---

## Notes for skill authors adapting this for other platforms

This skill is designed for macOS + NetWatch. To adapt it for other platforms or apps:

- **Incident directory**: replace `~/network_tests/incidents/` with your app's log path
- **Connector files**: `connector_<id>.txt` files in each bundle contain structured device
  data — adjust the interpretation hints in Section 5 for your devices
- **Platform check**: replace the `ls /Applications/NetWatch.app` check with whatever
  is appropriate for your platform (Windows registry, Linux systemd status, etc.)
- **Output format**: the Section 3 template is generic — it works for any network
  monitoring tool that produces ping/DNS/traceroute data

The diagnostic logic in Section 2 (WAN vs. local, severity classification, pattern
detection) is platform-agnostic and can be reused verbatim.
