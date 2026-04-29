import Foundation

/// Runs continuous ping for a single target and updates its PingState.
actor PingMonitor {
    private let state: PingState
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(state: PingState, interval: TimeInterval) {
        self.state = state
        self.interval = interval
    }

    func start() {
        task = Task {
            while !Task.isCancelled {
                await ping()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func ping() async {
        let host = await state.target.host
        // -c 1: one probe, -W 2000: 2s timeout (ms on macOS), -n: no reverse DNS
        let output = await ProcessRunner.runPermissive(
            "/sbin/ping",
            args: ["-c", "1", "-W", "2000", "-n", host],
            timeout: 5
        )

        let result = parsePingOutput(output, host: host)

        await MainActor.run {
            state.results.append(result)
            // Keep a rolling 100-sample window
            if state.results.count > 100 { state.results.removeFirst() }
            state.isOnline = result.success
        }
    }

    private func parsePingOutput(_ output: String, host: String) -> PingResult {
        // macOS ping output: "64 bytes from 1.1.1.1: icmp_seq=0 ttl=58 time=3.456 ms"
        for line in output.components(separatedBy: "\n") {
            if line.contains("bytes from") && line.contains("time=") {
                if let range = line.range(of: "time="),
                   let endRange = line.range(of: " ms", range: range.upperBound..<line.endIndex) {
                    let rttStr = String(line[range.upperBound..<endRange.lowerBound])
                    if let rtt = Double(rttStr) {
                        return PingResult(timestamp: Date(), host: host, rtt: rtt, success: true)
                    }
                }
            }
        }
        return PingResult(timestamp: Date(), host: host, rtt: nil, success: false)
    }
}
