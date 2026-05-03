/// MobileSettingsView.swift — Mac IP/port configuration + connection test

import SwiftUI

struct MobileSettingsView: View {
    @EnvironmentObject var connection: ConnectionState

    // Local edit state — commit on Save
    @State private var editIP:   String = ""
    @State private var editPort: String = ""
    @State private var testState: TestState = .idle

    enum TestState { case idle, testing, success(String), failure(String) }

    var body: some View {
        NavigationStack {
            Form {
                // ── Mac Connection ─────────────────────────────────────────────
                Section {
                    LabeledContent("Mac IP or hostname") {
                        TextField("192.168.x.x", text: $editIP)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    LabeledContent("Port") {
                        TextField("57821", text: $editPort)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                    }

                    Button("Save & Reconnect") {
                        save()
                    }
                    .disabled(editIP.trimmingCharacters(in: .whitespaces).isEmpty)

                } header: {
                    Text("Mac Connection")
                } footer: {
                    Text("Enter your Mac's local IP (e.g. 192.168.1.x) for home network access. When away, connect via WireGuard VPN first — then use your Mac's VPN IP (e.g. 10.x.x.x).")
                }

                // ── Test Connection ────────────────────────────────────────────
                Section {
                    HStack {
                        Button("Test Connection") {
                            Task { await testConnection() }
                        }
                        .disabled(testState == .idle ? false : true)

                        Spacer()

                        switch testState {
                        case .idle:
                            EmptyView()
                        case .testing:
                            ProgressView().scaleEffect(0.8)
                        case .success(let msg):
                            Label(msg, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Connectivity")
                }

                // ── Current Status ─────────────────────────────────────────────
                Section("Status") {
                    LabeledContent("Connection", value: connection.mode.label)

                    if let status = connection.status {
                        LabeledContent("Mac public IP", value: status.macPublicIP.isEmpty ? "–" : status.macPublicIP)
                        LabeledContent("Mac local IP",  value: status.macLocalIP.isEmpty  ? "–" : status.macLocalIP)
                        if !status.wifiSSID.isEmpty {
                            LabeledContent("SSID", value: status.wifiSSID)
                        }
                        LabeledContent("Gateway RTT", value: status.gatewayRTTFormatted)
                        LabeledContent("Mac version",  value: status.appVersion)
                    }

                    if let updated = connection.lastUpdated {
                        LabeledContent("Last updated", value: updated.formatted(.relative(presentation: .named)))
                    }
                }

                // ── WireGuard Guide ────────────────────────────────────────────
                Section {
                    DisclosureGroup("Away Mode Setup (WireGuard)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("To monitor your network from anywhere:")
                                .font(.caption.bold())
                            step("1", "Install WireGuard on your iPhone from the App Store.")
                            step("2", "Import your WireGuard profile (your Firewalla generates this — check Firewalla app → VPN → WireGuard).")
                            step("3", "Connect to the VPN when away from home.")
                            step("4", "Enter your Mac's WireGuard VPN IP here (typically 10.x.x.x — shown in WireGuard tunnel details).")
                            step("5", "NetWatch Mobile will detect away mode automatically and show the VPN banner.")
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Remote Access")
                }

                // ── About ──────────────────────────────────────────────────────
                Section {
                    LabeledContent("API endpoint") {
                        Text("http://\(connection.client.macIP):\(connection.client.macPort)/health")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Debug")
                }
            }
            .navigationTitle("Settings")
            .onAppear { loadCurrentConfig() }
        }
    }

    // MARK: - Actions

    private func loadCurrentConfig() {
        editIP   = connection.client.macIP
        editPort = "\(connection.client.macPort)"
    }

    private func save() {
        let ip   = editIP.trimmingCharacters(in: .whitespaces)
        let port = UInt16(editPort) ?? 57821
        connection.client.macIP   = ip
        connection.client.macPort = port
        connection.reconfigure()
        testState = .idle
    }

    private func testConnection() async {
        testState = .testing
        let ok = await connection.client.testConnection()
        testState = ok
            ? .success("Connected ✓")
            : .failure("No response")

        // Auto-clear success after 3 seconds
        if case .success = testState {
            try? await Task.sleep(for: .seconds(3))
            testState = .idle
        }
    }

    // MARK: - Helpers

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number + ".")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - TestState Equatable

extension MobileSettingsView.TestState: Equatable {
    static func == (lhs: MobileSettingsView.TestState, rhs: MobileSettingsView.TestState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.testing, .testing): return true
        case (.success(let a), .success(let b)):   return a == b
        case (.failure(let a), .failure(let b)):   return a == b
        default: return false
        }
    }
}
