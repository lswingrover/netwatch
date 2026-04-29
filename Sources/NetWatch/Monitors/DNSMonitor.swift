import Foundation

actor DNSMonitor {
    private let state: DNSState
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(state: DNSState, interval: TimeInterval) {
        self.state = state
        self.interval = interval
    }

    func start() {
        task = Task {
            while !Task.isCancelled {
                await query()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func query() async {
        let domain = await state.target.domain
        // +stats gives us Query time; +time=2 sets 2s timeout
        let output = await ProcessRunner.runPermissive(
            "/usr/bin/dig",
            args: [domain, "+stats", "+time=2", "+tries=1"],
            timeout: 5
        )
        let result = parseDNSOutput(output, domain: domain)
        await MainActor.run {
            state.results.append(result)
            if state.results.count > 50 { state.results.removeFirst() }
        }
    }

    private func parseDNSOutput(_ output: String, domain: String) -> DNSResult {
        var status = "TIMEOUT"
        var queryTime: Double? = nil

        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            // ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: ..."
            if t.contains("status:") {
                let parts = t.components(separatedBy: "status:")
                if parts.count > 1 {
                    let rest = parts[1].trimmingCharacters(in: .whitespaces)
                    // "NOERROR, id: 12345"
                    status = rest.components(separatedBy: ",").first?
                        .trimmingCharacters(in: .whitespaces) ?? "UNKNOWN"
                    status = status.components(separatedBy: CharacterSet.alphanumerics.inverted)
                        .joined()
                }
            }
            // ";; Query time: 23 msec"
            if t.hasPrefix(";; Query time:") {
                let nums = t.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .filter { !$0.isEmpty }
                if let ms = nums.first, let val = Double(ms) {
                    queryTime = val
                }
            }
        }

        return DNSResult(
            timestamp: Date(),
            domain: domain,
            queryTime: queryTime,
            status: status
        )
    }
}
