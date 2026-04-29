import Foundation

/// Samples netstat -ibn to compute RX/TX rates and packet/error counters.
@MainActor
class InterfaceMonitor: ObservableObject {
    @Published var currentRate: InterfaceRate = InterfaceRate(rxBytesPerSec: 0, txBytesPerSec: 0,
                                                              rxPacketsPerSec: 0, txPacketsPerSec: 0,
                                                              rxErrors: 0, txErrors: 0)
    @Published var interface: String = ""
    @Published var ipAddress: String = ""
    @Published var gateway: String = ""
    @Published var gatewayRTT: Double? = nil
    @Published var rttHistory: [Double] = []
    @Published var bandwidthHistory: [BandwidthSample] = []
    @Published var tcpEstablished: Int = 0
    @Published var publicIP: String = ""
    @Published var linkMedia: String = ""
    @Published var mtu: Int = 0

    // Wi-Fi (empty strings when on Ethernet)
    @Published var wifiSSID:      String = ""
    @Published var wifiRSSI:      Int    = 0
    @Published var wifiNoise:     Int    = 0
    @Published var wifiChannel:   String = ""
    @Published var wifiMCS:       Int    = 0
    @Published var wifiTxRate:    Int    = 0
    @Published var wifiRetryRate: Double = 0   // fraction 0–1, e.g. 0.12 = 12 %
    var wifiSNR: Int { wifiRSSI - wifiNoise }  // positive dB = better

    // Link flap tracking
    @Published var interfaceUp: Bool       = true
    @Published var linkFlaps:   [LinkFlap] = []   // capped at 50

    private var prevSnapshot: InterfaceSnapshot? = nil
    private var task: Task<Void, Never>? = nil
    private var gatewayTask: Task<Void, Never>? = nil
    private var publicIPTask: Task<Void, Never>? = nil
    private var wifiTask: Task<Void, Never>? = nil
    private let interval: TimeInterval

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    func start(interface: String) {
        Task {
            let iface = interface.isEmpty ? await ProcessRunner.defaultInterface() : interface
            let ip    = await ProcessRunner.interfaceIP(iface)
            let gw    = await ProcessRunner.gatewayIP()
            await MainActor.run {
                self.interface = iface
                self.ipAddress = ip
                self.gateway   = gw
            }
        }

        task = Task {
            while !Task.isCancelled {
                await sampleStats()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }

        // Gateway ping every 2s
        gatewayTask = Task {
            while !Task.isCancelled {
                await pingGateway()
                await sampleTCPConnections()
                await sampleLinkMedia()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        // Public IP every 5 min
        publicIPTask = Task {
            while !Task.isCancelled {
                await fetchPublicIP()
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }

        // Wi-Fi stats every 5s
        wifiTask = Task {
            while !Task.isCancelled {
                await sampleWiFi()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        gatewayTask?.cancel(); gatewayTask = nil
        publicIPTask?.cancel(); publicIPTask = nil
        wifiTask?.cancel(); wifiTask = nil
    }

    // MARK: - Private

    private func sampleStats() async {
        let iface = await self.interface
        guard !iface.isEmpty else { return }

        let output = await ProcessRunner.runPermissive("/usr/bin/netstat", args: ["-ibn"])
        let snapshot = parseNetstat(output, interface: iface)

        // Link flap detection
        if snapshot == nil && interfaceUp && prevSnapshot != nil {
            interfaceUp = false
            let flap = LinkFlap(timestamp: Date(), event: "down")
            linkFlaps.insert(flap, at: 0)
            if linkFlaps.count > 50 { linkFlaps.removeLast() }
        } else if snapshot != nil && !interfaceUp {
            interfaceUp = true
            let flap = LinkFlap(timestamp: Date(), event: "up")
            linkFlaps.insert(flap, at: 0)
            if linkFlaps.count > 50 { linkFlaps.removeLast() }
        }

        guard let snap = snapshot else { return }

        let now = Date()
        var rate = InterfaceRate(rxBytesPerSec: 0, txBytesPerSec: 0,
                                 rxPacketsPerSec: 0, txPacketsPerSec: 0,
                                 rxErrors: snap.rxErrors, txErrors: snap.txErrors)

        if let prev = prevSnapshot {
            let dt = now.timeIntervalSince(prev.timestamp)
            if dt > 0 {
                let drx = max(0, snap.rxBytes - prev.rxBytes)
                let dtx = max(0, snap.txBytes - prev.txBytes)
                let dpkrx = max(0, snap.rxPackets - prev.rxPackets)
                let dpktx = max(0, snap.txPackets - prev.txPackets)
                rate = InterfaceRate(
                    rxBytesPerSec:   Double(drx) / dt,
                    txBytesPerSec:   Double(dtx) / dt,
                    rxPacketsPerSec: Double(dpkrx) / dt,
                    txPacketsPerSec: Double(dpktx) / dt,
                    rxErrors:        snap.rxErrors,
                    txErrors:        snap.txErrors
                )
            }
        }

        prevSnapshot = snap
        currentRate = rate

        // Bandwidth history (push non-zero samples; cap at 120 → 2 min at 1s interval)
        if rate.rxBytesPerSec > 0 || rate.txBytesPerSec > 0 {
            let sample = BandwidthSample(timestamp: now,
                                         rxBytesPerSec: rate.rxBytesPerSec,
                                         txBytesPerSec: rate.txBytesPerSec)
            bandwidthHistory.append(sample)
            if bandwidthHistory.count > 120 { bandwidthHistory.removeFirst() }
        }
    }

    private func parseNetstat(_ output: String, interface iface: String) -> InterfaceSnapshot? {
        // netstat -ibn columns (macOS):
        // Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
        var rxBytes: Int64 = 0; var txBytes: Int64 = 0
        var rxPkts: Int64 = 0;  var txPkts: Int64 = 0
        var rxErr: Int64 = 0;   var txErr: Int64 = 0
        var found = false

        var parsedMTU: Int = 0
        for line in output.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 10, cols[0] == iface else { continue }
            found = true
            if parsedMTU == 0, cols.count >= 2 { parsedMTU = Int(cols[1]) ?? 0 }
            rxPkts  += Int64(cols[4]) ?? 0
            rxErr   += Int64(cols[5]) ?? 0
            rxBytes += Int64(cols[6]) ?? 0
            txPkts  += Int64(cols[7]) ?? 0
            txErr   += Int64(cols[8]) ?? 0
            txBytes += Int64(cols[9]) ?? 0
        }
        if parsedMTU > 0 { mtu = parsedMTU }

        guard found else { return nil }
        return InterfaceSnapshot(timestamp: Date(), interface: iface,
                                 rxBytes: rxBytes, txBytes: txBytes,
                                 rxPackets: rxPkts, txPackets: txPkts,
                                 rxErrors: rxErr, txErrors: txErr)
    }

    private func pingGateway() async {
        let gw = await self.gateway
        guard !gw.isEmpty else { return }
        let out = await ProcessRunner.runPermissive("/sbin/ping", args: ["-c", "1", "-W", "1000", "-n", gw], timeout: 3)
        var rtt: Double? = nil
        for line in out.components(separatedBy: "\n") {
            if line.contains("time="), let r = line.range(of: "time="),
               let e = line.range(of: " ms", range: r.upperBound..<line.endIndex) {
                rtt = Double(String(line[r.upperBound..<e.lowerBound]))
            }
        }
        await MainActor.run {
            self.gatewayRTT = rtt
            if let r = rtt {
                self.rttHistory.append(r)
                if self.rttHistory.count > 60 { self.rttHistory.removeFirst() }
            }
        }
    }

    private func sampleTCPConnections() async {
        let out = await ProcessRunner.runPermissive("/usr/bin/netstat", args: ["-anp", "tcp"])
        let count = out.components(separatedBy: "\n").filter { $0.contains("ESTABLISHED") }.count
        await MainActor.run { self.tcpEstablished = count }
    }

    private func sampleLinkMedia() async {
        let iface = await self.interface
        let out = await ProcessRunner.runPermissive("/sbin/ifconfig", args: [iface])
        var media = ""
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("media:") {
                media = t.replacingOccurrences(of: "media:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                // Extract parenthetical if present
                if let open = media.firstIndex(of: "("),
                   let close = media.lastIndex(of: ")") {
                    media = String(media[media.index(after: open)..<close])
                }
                break
            }
        }
        await MainActor.run { self.linkMedia = media }
    }

    private func sampleWiFi() async {
        let airport = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
        let out = await ProcessRunner.runPermissive(airport, args: ["-I"], timeout: 5)
        guard !out.isEmpty else { return }

        var ssid = "", channel = ""
        var rssi = 0, noise = 0, mcsVal = 0, txRate = 0
        var retryRatePct = 0.0

        for line in out.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: ": ")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let val = parts[1...].joined(separator: ": ").trimmingCharacters(in: .whitespaces)
            switch key {
            case "SSID":           ssid         = val
            case "agrCtlRSSI":     rssi         = Int(val) ?? 0
            case "agrCtlNoise":    noise        = Int(val) ?? 0
            case "channel":        channel      = val.components(separatedBy: ",")[0]
            case "MCS":            mcsVal       = Int(val) ?? 0
            case "lastTxRate":     txRate       = Int(val) ?? 0
            case "agrCtlRetryRate": retryRatePct = Double(val) ?? 0
            default: break
            }
        }

        await MainActor.run {
            self.wifiSSID       = ssid
            self.wifiRSSI       = rssi
            self.wifiNoise      = noise
            self.wifiChannel    = channel
            self.wifiMCS        = mcsVal
            self.wifiTxRate     = txRate
            self.wifiRetryRate  = retryRatePct / 100.0
        }
    }

    private func fetchPublicIP() async {
        let out = await ProcessRunner.runPermissive("/usr/bin/curl", args: ["-s", "--max-time", "10", "https://ifconfig.me"])
        let ip = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ip.isEmpty {
            await MainActor.run { self.publicIP = ip }
        }
    }
}

// MARK: - Human readable bytes/s

extension Double {
    var humanBytes: String {
        if self < 1024        { return String(format: "%.0f B", self) }
        if self < 1_048_576   { return String(format: "%.1f KB", self / 1024) }
        if self < 1_073_741_824 { return String(format: "%.1f MB", self / 1_048_576) }
        return String(format: "%.1f GB", self / 1_073_741_824)
    }
}
