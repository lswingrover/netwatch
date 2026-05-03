# NetWatch Mobile — Xcode Setup Guide

The iOS source files live in `Sources/NetWatchMobile/`. Because the Mac app uses Swift
Package Manager (not an Xcode project), you need to create a separate Xcode project for
the iOS build. Here's the exact sequence:

---

## Step 1 — Create a new Xcode iOS project

1. Open Xcode → **File → New → Project…**
2. Choose **iOS → App**
3. Settings:
   - **Product Name:** NetWatchMobile
   - **Bundle Identifier:** com.yourname.NetWatchMobile
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Minimum Deployments:** iOS 17.0
4. Save it into `~/Developer/NetWatch/` (or a sibling directory)

---

## Step 2 — Replace the default source files

Delete the default `ContentView.swift` and `NetWatchMobileApp.swift` that Xcode created.

In Finder, drag the files from `Sources/NetWatchMobile/` into the Xcode project:

```
Sources/NetWatchMobile/
├── NetWatchMobileApp.swift
├── Models/
│   ├── APIClient.swift
│   ├── APIModels.swift
│   └── ConnectionState.swift
└── Views/
    ├── ContentView.swift
    ├── MobileOverviewView.swift
    ├── MobileConnectorsView.swift
    ├── MobileIncidentsView.swift
    └── MobileSettingsView.swift
```

When Xcode asks, choose **Copy items if needed** and add to the **NetWatchMobile** target.

---

## Step 3 — Add entitlements (for network access)

The app fetches from `http://` (not `https://`) on the local LAN. You need to allow
arbitrary loads:

1. Select the **NetWatchMobile** target → **Info** tab
2. Add key: **NSAppTransportSecurity** (Dictionary)
3. Under it, add: **NSAllowsArbitraryLoads** → **YES**

Or add this to Info.plist directly:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

---

## Step 4 — Build and run

Select your iPhone or simulator. Press **⌘R**.

On first launch you'll see the Settings screen — enter your Mac's local IP (e.g.
`192.168.1.x`) and tap **Save & Reconnect**. Then tap **Test Connection** to verify.

---

## Step 5 — Test the Mac API first (optional but recommended)

Before building the iOS app, verify the Mac API server is running:

```bash
# Enable in NetWatch → Preferences → Alerting → Mobile API
# Then from Terminal:
curl http://localhost:57821/health | python3 -m json.tool
curl http://localhost:57821/status | python3 -m json.tool
curl http://localhost:57821/connectors | python3 -m json.tool
```

---

## Away Mode (WireGuard VPN)

When you're away from home:
1. Activate your WireGuard profile on your iPhone (imported from Firewalla)
2. In NetWatch Mobile → Settings, enter your Mac's WireGuard VPN IP (e.g. `10.6.0.1`)
3. The app will auto-detect away mode and show the VPN banner

---

## Shared model types

The iOS `APIModels.swift` mirrors the Mac `NetWatchAPIServer.swift` payload types.
If you extend the API on the Mac side, update both files. The fields that must stay
in sync:

| Mac type              | iOS type              |
|-----------------------|-----------------------|
| `APIHealthPayload`    | `APIHealthPayload`    |
| `APIConnectorPayload` | `APIConnectorPayload` |
| `APIMetric`           | `APIMetric`           |
| `APIEvent`            | `APIEvent`            |
| `APIStatusPayload`    | `APIStatusPayload`    |
| `APIIncidentSummary`  | `APIIncidentSummary`  |
