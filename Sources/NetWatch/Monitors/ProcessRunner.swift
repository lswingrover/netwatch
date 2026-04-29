import Foundation

/// Thin async wrapper around Process. Runs a command and returns stdout, or throws on non-zero exit.
enum ProcessRunner {

    struct ProcessError: Error, LocalizedError {
        let command: String
        let exitCode: Int32
        let stderr: String
        var errorDescription: String? { "'\(command)' exited \(exitCode): \(stderr)" }
    }

    /// Run a command. Returns stdout string. Throws on non-zero exit.
    @discardableResult
    static func run(_ executable: String, args: [String], timeout: TimeInterval = 30) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var timeoutTask: Task<Void, Never>?

            process.terminationHandler = { p in
                timeoutTask?.cancel()
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                if p.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: ProcessError(
                        command: "\(executable) \(args.joined(separator: " "))",
                        exitCode: p.terminationStatus,
                        stderr: stderr
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Timeout watchdog
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled && process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    /// Run a command, returning stdout even on non-zero exit (for ping which exits 1 on loss).
    static func runPermissive(_ executable: String, args: [String], timeout: TimeInterval = 30) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()   // discard stderr

            var timeoutTask: Task<Void, Never>?

            process.terminationHandler = { _ in
                timeoutTask?.cancel()
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }

            guard (try? process.run()) != nil else {
                continuation.resume(returning: "")
                return
            }

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled && process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    /// Detect the default network interface via `route get default`.
    static func defaultInterface() async -> String {
        let out = await runPermissive("/sbin/route", args: ["get", "default"])
        for line in out.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        return "en0"
    }

    /// Get IPv4 address for an interface.
    static func interfaceIP(_ iface: String) async -> String {
        let out = await runPermissive("/usr/sbin/ipconfig", args: ["getifaddr", iface])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get default gateway IP.
    static func gatewayIP() async -> String {
        let out = await runPermissive("/sbin/route", args: ["-n", "get", "default"])
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return t.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
