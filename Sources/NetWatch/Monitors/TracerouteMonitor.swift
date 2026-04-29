import Foundation

@MainActor
class TracerouteMonitor: ObservableObject {
    @Published var results: [String: TracerouteResult] = [:]   // target → result
    @Published var currentTarget: String = ""
    @Published var isRunning: Bool = false

    private var targets: [String] = []
    private var targetIndex: Int = 0
    private var task: Task<Void, Never>? = nil
    private let interval: TimeInterval

    init(interval: TimeInterval = 60.0) {
        self.interval = interval
    }

    func start(targets: [String]) {
        self.targets = targets
        self.targetIndex = 0
        guard !targets.isEmpty else { return }
        task = Task {
            while !Task.isCancelled {
                await runNext()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func runNow(target: String) {
        Task { await run(target: target) }
    }

    // MARK: - Private

    private func runNext() async {
        guard !targets.isEmpty else { return }
        let target = targets[targetIndex % targets.count]
        targetIndex += 1
        await run(target: target)
    }

    private func run(target: String) async {
        await MainActor.run {
            currentTarget = target
            isRunning = true
        }

        // -m 20: max hops, -q 1: one probe per hop, -w 1: 1s timeout per hop, -n: no DNS
        let output = await ProcessRunner.runPermissive(
            "/usr/sbin/traceroute",
            args: ["-m", "20", "-q", "3", "-w", "2", "-n", target],
            timeout: 90
        )

        let hops = parseTraceroute(output)
        let result = TracerouteResult(target: target, hops: hops, timestamp: Date())

        await MainActor.run {
            results[target] = result
            isRunning = false
        }
    }

    private func parseTraceroute(_ output: String) -> [TracerouteHop] {
        var hops: [TracerouteHop] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("traceroute") else { continue }

            let cols = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let hopNum = Int(cols.first ?? "") else { continue }

            // Format: "N  host  rtt1 ms  rtt2 ms  rtt3 ms"
            // or:    "N  * * *"  (timeout)

            var ipOrHost: String? = nil
            var rtts: [Double] = []

            var i = 1
            while i < cols.count {
                let col = cols[i]
                if col == "*" {
                    rtts.append(-1)  // sentinel for *
                    i += 1
                } else if col == "ms" {
                    i += 1
                } else if let rtt = Double(col) {
                    rtts.append(rtt)
                    i += 1
                } else if ipOrHost == nil && !col.isEmpty {
                    // IP address or hostname
                    ipOrHost = col
                    i += 1
                } else {
                    i += 1
                }
            }

            let validRTTs = rtts.filter { $0 >= 0 }
            let hop = TracerouteHop(
                id: hopNum,
                host: nil,
                ip: ipOrHost,
                rtt1: rtts.count > 0 && rtts[0] >= 0 ? rtts[0] : nil,
                rtt2: rtts.count > 1 && rtts[1] >= 0 ? rtts[1] : nil,
                rtt3: rtts.count > 2 && rtts[2] >= 0 ? rtts[2] : nil
            )
            _ = validRTTs  // used implicitly via hop
            hops.append(hop)
        }

        return hops
    }
}
