# NetWatch Diagnose — Claude Skill

A companion skill for [NetWatch](https://github.com/lswingrover/NetWatch) that
uses Claude to diagnose network problems from incident bundles and live device data.

## What it does

When you run this skill, Claude will:

1. **Check if NetWatch is installed** — and walk you through setup if it isn't.
2. **Load your most recent incident bundle** — the structured data NetWatch captures
   whenever ping or DNS thresholds are breached.
3. **Run a root-cause chain analysis** — distinguishing WAN outages from router issues,
   DNS failures, and local blips.
4. **Read connector data** — if you have a Firewalla or Nighthawk connector enabled,
   Claude correlates security events, router uptime, WAN IP changes, and CPU/memory
   pressure with the network failure timeline.
5. **Deliver a plain-English diagnosis** with specific recommended actions, including
   a pre-filled ISP escalation draft ready to send.

## Install

### Option A — Install as a Claude Cowork plugin (recommended)

1. Open Claude desktop app.
2. Go to **Plugins → Install from folder**.
3. Select the `skill/` folder inside your NetWatch repo.
4. The skill will appear as **NetWatch Diagnose** in your skill list.

### Option B — Manual install (any Claude session)

1. Copy the contents of `skill/SKILL.md` into a Claude conversation.
2. Ask Claude: "Run this skill."

### Option C — Copy to your Claude skills folder

```bash
mkdir -p ~/Documents/Claude/skills/netwatch-diagnose
cp skill/SKILL.md ~/Documents/Claude/skills/netwatch-diagnose/SKILL.md
```

Then reference it in your Claude sessions by asking: "Run the netwatch-diagnose skill."

## Using the skill

After install, in any Claude session (Cowork or API):

```
Run the NetWatch Diagnose skill
```

or just:

```
Diagnose my last network outage using NetWatch
```

Claude will automatically locate your incident bundles, read the data, and produce
a diagnosis.

## Prerequisites

- **NetWatch** installed and running (or previously run) — https://github.com/lswingrover/NetWatch#install
- At least one incident captured (NetWatch creates these automatically when failures occur)
- Optional but highly recommended: **Connectors enabled** in NetWatch (Settings → Connectors)
  — Firewalla and Nighthawk data dramatically improve diagnosis quality

## Extending for other platforms

This skill is written for macOS + NetWatch but the diagnostic logic is platform-agnostic.
See the "Notes for skill authors" section at the bottom of `SKILL.md` for guidance on
adapting it for other network monitoring tools or operating systems.

## How NetWatch connectors improve diagnosis

When connectors are enabled, incident bundles include `connector_<id>.txt` files
alongside the standard ping/DNS/traceroute data. Claude uses these to answer questions like:

- Did the router reboot during the outage? (Nighthawk uptime < 5 min)
- Was the outage confirmed at the WAN level? (Firewalla WAN RX dropped to zero)
- Did a Firewalla rule block legitimate traffic? (active alarms during the incident)
- Is this a recurring ISP problem or a local hardware issue? (pattern across bundles)

To enable connectors: **NetWatch → Settings → Connectors → enable Firewalla or Nighthawk**
and enter your device's local IP + credentials.
