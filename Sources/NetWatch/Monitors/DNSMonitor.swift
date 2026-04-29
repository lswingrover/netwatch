import Foundation

/// DNS resolvers used for multi-resolver comparison.
let kDNSResolvers: [(label: String, ip: String?)] = [
    ("System",     nil),
    ("Cloudflare", "1.1.1.1"),
    ("Google",     "8.8.8.8"),
    ("Quad9",      "9.9.9.9"),
]

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

    // MARK: - Primary query + multi-resolver comparison

    private func query() async {
        let domain = await state.target.domain

        // Run all resolvers concurrently
        async let systemResult = singleQuery(domain: domain, resolver: nil)
        async let cfResult     = singleQuery(domain: domain, resolver: "1.1.1.1")
        async let googleResult = singleQuery(domain: domain, resolver: "8.8.8.8")
        async let quad9Result  = singleQuery(domain: domain, resolver: "9.9.9.9")

        let (primary, cf, goog, q9) = await (systemResult, cfResult, googleResult, quad9Result)

        let resolverMap: [String: Double?] = [
            "System":     primary.queryTime,
            "Cloudflare": cf.queryTime,
            "Google":     goog.queryTime,
            "Quad9":      q9.queryTime,
        ]

        await MainActor.run {
            state.results.append(primary)
            if state.results.count > 50 { state.results.removeFirst() }
            state.resolverTimes = resolverMap
        }
    }

    // MARK: - Single dig query to a specific resolver (nil = system default)

    private func singleQuery(domain: String, resolver: String?) async -> DNSResult {
        var args = [domain, "+stats", "+time=2", "+tries=1"]
        if let r = resolver { args = ["@\(r)"] + args }
        let output = await ProcessRunner.runPermissive(
            "/usr/bin/dig", args: args, timeout: 5
        )
        return parseDNSOutput(output, domain: domain)
    }

    // MARK: - Parser

    private func parseDNSOutput(_ output: String, domain: String) -> DNSResult {
        var status     = "TIMEOUT"
        var queryTime: Double? = nil

        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.contains("status:") {
                let parts = t.components(separatedBy: "status:")
                if parts.count > 1 {
                    let rest = parts[1].trimmingCharacters(in: .whitespaces)
                    status = rest.components(separatedBy: ",").first?
                        .trimmingCharacters(in: .whitespaces) ?? "UNKNOWN"
                    status = status.components(separatedBy: CharacterSet.alphanumerics.inverted)
                        .joined()
                }
            }

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
            domain:    domain,
            queryTime: queryTime,
            status:    status
        )
    }
}
