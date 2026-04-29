# NetWatch — Build Instructions

## Prerequisites
- Xcode 15+ (macOS 14 SDK)
- macOS 14 Sonoma or later

## Open in Xcode
```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Claude/NetWatch
xed .
```
Xcode opens the Swift package. It auto-creates the scheme.

## Run
1. Select the **NetWatch** scheme in Xcode
2. Set destination to **My Mac**
3. ⌘R to build and run

## Add the App Icon
The `AppIcon.appiconset` is wired but empty (no PNG files committed).
To add an icon:
1. Open `/Sources/NetWatch/Resources/Assets.xcassets` in Xcode
2. Drop a 1024×1024 PNG onto the AppIcon slot
   - Or use [Icon Set Creator](https://apps.apple.com/app/icon-set-creator/id939343785) to generate all sizes

**Quick placeholder icon** (renders a network-wave SF Symbol on a blue background):
```swift
// Paste this into a scratch Playground to generate icon PNG files programmatically
// or just skip the icon for development builds — the app runs fine without it.
```

## Entitlements
The app uses only standard userland tools (ping, dig, netstat, traceroute, curl) via
`Process`. No special entitlements are required for local builds. For notarization:
- Add `com.apple.security.app-sandbox` = NO (or properly sandbox with network client)
- Add `com.apple.security.files.user-selected.read-write` if sandboxed

## Move to Developer folder (optional)
```bash
cp -r ~/Library/Mobile\ Documents/com~apple~CloudDocs/Claude/NetWatch \
      ~/Developer/NetWatch
cd ~/Developer/NetWatch
xed .
```

## Sudo note for packet capture
`tcpdump` (used in incident bundles) requires root. The app runs without it — capture
is attempted opportunistically and skipped if permission is denied.
