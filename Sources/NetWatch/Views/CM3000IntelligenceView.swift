/// CM3000IntelligenceView.swift — Rich Netgear CM3000 modem panel for NetWatch
///
/// Tabs:
///   Overview  — Signal health tiles + DOCSIS-spec educational callouts + issue guidance
///   Channels  — Per-channel downstream table (SC-QAM + OFDM) with SNR/power/codewords
///   Events    — Connector event list (modem log messages, startup failures)
///   History   — ConnectorTimelineView trend chart
///
/// Design intent: The CM3000 DOCSIS event log uses the modem's own conservative
/// thresholds (e.g. "SNR is poor at 43 dB" when the DOCSIS 3.0 minimum is 30 dB).
/// This view always shows the DOCSIS-spec interpretation alongside the raw value so
/// the user understands whether a modem warning is actionable or just noise.

import SwiftUI

struct CM3000IntelligenceView: View {
    @EnvironmentObject var connectorManager: ConnectorManager

    private var cm3000: CM3000Connector? {
        connectorManager.connectors.first(where: { $0.id == "cm3000" }) as? CM3000Connector
    }

    private var snapshot: ConnectorSnapshot? {
        connectorManager.snapshot(for: "cm3000")
    }

    @State private var tab: CM3000Tab = .overview

    enum CM3000Tab: String, CaseIterable {
        case overview = "Overview"
        case channels = "Channels"
        case events   = "Events"
        case history  = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            if snapshot != nil || cm3000 != nil {
                Picker("Tab", selection: $tab) {
                    ForEach(CM3000Tab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                Divider()

                switch tab {
                case .overview:  overviewTab
                case .channels:  channelsTab
                case .events:    eventsTab
                case .history:   ConnectorTimelineView(connectorId: "cm3000")
                }
            } else {
                unavailableView
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "cable.connector.horizontal")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Netgear CM3000")
                    .font(.headline)
                if let snap = snapshot {
                    Text(snap.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let snap = snapshot {
                Text(snap.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                connectorManager.pollNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Refresh CM3000 now")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Overview tab

    @ViewBuilder
    private var overviewTab: some View {
        if let snap = snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    signalHealthTiles(snap)
                    signalContextCards(snap)
                    issueGuidanceSection(snap)
                    Spacer(minLength: 40)
                }
                .padding(20)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for CM3000 data…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Signal health tiles (4 primary indicators)

    private func signalHealthTiles(_ snap: ConnectorSnapshot) -> some View {
        let avgSNR      = snap.metrics.first(where: { $0.key == "avg_snr_db" })
        let dsPwr       = snap.metrics.first(where: { $0.key == "avg_ds_power" })
        let usPwr       = snap.metrics.first(where: { $0.key == "avg_us_power" })
        let startup     = snap.metrics.first(where: { $0.key == "startup_ok" })
        let dsChannels  = snap.metrics.first(where: { $0.key == "ds_channels" })
        let usChannels  = snap.metrics.first(where: { $0.key == "us_channels" })
        let uncorr      = snap.metrics.first(where: { $0.key == "total_uncorr_codewords" })

        return VStack(alignment: .leading, spacing: 12) {
            Text("Signal Health")
                .font(.headline)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: 4),
                spacing: 12
            ) {
                // DS SNR
                CM3000Tile(
                    icon:  "waveform.path.ecg",
                    label: "DS SNR",
                    value: avgSNR.map { String(format: "%.1f", $0.value) } ?? "–",
                    unit:  "dB",
                    color: severityColor(avgSNR?.severity)
                )

                // DS Rx Power
                CM3000Tile(
                    icon:  "arrow.down.circle.fill",
                    label: "DS Rx Power",
                    value: dsPwr.map { String(format: "%+.1f", $0.value) } ?? "–",
                    unit:  "dBmV",
                    color: severityColor(dsPwr?.severity)
                )

                // US Tx Power
                CM3000Tile(
                    icon:  "arrow.up.circle.fill",
                    label: "US Tx Power",
                    value: usPwr.map { String(format: "%.1f", $0.value) } ?? "–",
                    unit:  "dBmV",
                    color: severityColor(usPwr?.severity)
                )

                // DOCSIS Init
                let initOK = (startup?.value ?? 1) > 0
                CM3000Tile(
                    icon:  initOK ? "checkmark.seal.fill" : "xmark.seal.fill",
                    label: "DOCSIS Init",
                    value: startup?.unit ?? "–",
                    unit:  "",
                    color: initOK ? .green : .red
                )

                // Channel counts
                CM3000Tile(
                    icon:  "arrow.down.to.line",
                    label: "DS Channels",
                    value: dsChannels.map { String(Int($0.value)) } ?? "–",
                    unit:  "bonded",
                    color: .blue
                )

                CM3000Tile(
                    icon:  "arrow.up.to.line",
                    label: "US Channels",
                    value: usChannels.map { String(Int($0.value)) } ?? "–",
                    unit:  "bonded",
                    color: .blue
                )

                // Uncorrectable codewords
                let uncorrCount = Int(uncorr?.value ?? 0)
                CM3000Tile(
                    icon:  uncorrCount == 0 ? "checkmark.circle" : "exclamationmark.triangle",
                    label: "Uncorr CWs",
                    value: uncorrCount == 0 ? "0" : "\(uncorrCount)",
                    unit:  uncorrCount == 0 ? "clean" : "cumul.",
                    color: uncorrCount == 0 ? .green : .orange
                )

                // Partial service
                let hasPartialService = snap.events.contains { $0.type == "partial_service" }
                CM3000Tile(
                    icon:  hasPartialService ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                    label: "Partial Svc",
                    value: hasPartialService ? "ACTIVE" : "None",
                    unit:  "",
                    color: hasPartialService ? .red : .green
                )
            }
        }
    }

    // MARK: - Signal context callout cards (educational)

    @ViewBuilder
    private func signalContextCards(_ snap: ConnectorSnapshot) -> some View {
        let avgSNR   = snap.metrics.first(where: { $0.key == "avg_snr_db" })?.value
        let dsPwr    = snap.metrics.first(where: { $0.key == "avg_ds_power" })?.value
        let usPwr    = snap.metrics.first(where: { $0.key == "avg_us_power" })?.value
        let uncorr   = Int(snap.metrics.first(where: { $0.key == "total_uncorr_codewords" })?.value ?? 0)

        VStack(alignment: .leading, spacing: 10) {
            Text("Signal Interpretation")
                .font(.headline)

            // DS SNR card
            if let snr = avgSNR {
                let snrStatus: (color: Color, headline: String, detail: String) = {
                    if snr >= 40 {
                        return (.green,
                                "DS SNR \(String(format: "%.1f", snr)) dB — Excellent",
                                "Well above the DOCSIS 3.0 minimum (30 dB) and ISP recommended headroom (33 dB). Your downstream signal quality is strong.")
                    } else if snr >= 33 {
                        return (.green,
                                "DS SNR \(String(format: "%.1f", snr)) dB — Good",
                                "Above DOCSIS 3.0 recommended headroom (33 dB). Any modem messages about 'poor SNR' use a more conservative internal threshold; your signal meets spec.")
                    } else if snr >= 30 {
                        return (.yellow,
                                "DS SNR \(String(format: "%.1f", snr)) dB — Marginal",
                                "Between the DOCSIS 3.0 minimum (30 dB) and the recommended headroom (33 dB). Service should work but headroom is slim. Check for loose coax connectors.")
                    } else {
                        return (.red,
                                "DS SNR \(String(format: "%.1f", snr)) dB — Below DOCSIS Spec",
                                "Below the DOCSIS 3.0 minimum (30 dB). Packet errors and retransmissions are likely. Contact your ISP — this requires a technician visit.")
                    }
                }()
                CM3000ContextCard(color: snrStatus.color, headline: snrStatus.headline, detail: snrStatus.detail)
            }

            // DS Rx Power card
            if let pwr = dsPwr {
                let absPwr = abs(pwr)
                let pwrStatus: (color: Color, headline: String, detail: String) = {
                    if absPwr <= 7 {
                        return (.green,
                                "DS Rx Power \(String(format: "%+.1f", pwr)) dBmV — Ideal",
                                "Within the ±7 dBmV sweet spot. Your downstream receive power is optimal.")
                    } else if absPwr <= 10 {
                        return (.green,
                                "DS Rx Power \(String(format: "%+.1f", pwr)) dBmV — Good",
                                "Within acceptable range (DOCSIS spec: ±15 dBmV). Headroom is comfortable.")
                    } else if absPwr <= 15 {
                        return (.yellow,
                                "DS Rx Power \(String(format: "%+.1f", pwr)) dBmV — Approaching Limit",
                                "Approaching the DOCSIS spec edge (±15 dBmV). Could indicate signal attenuation or amplification issues at the tap.")
                    } else {
                        return (.red,
                                "DS Rx Power \(String(format: "%+.1f", pwr)) dBmV — Out of Spec",
                                "Outside the DOCSIS spec (±15 dBmV). Likely a plant-side issue — contact your ISP.")
                    }
                }()
                CM3000ContextCard(color: pwrStatus.color, headline: pwrStatus.headline, detail: pwrStatus.detail)
            }

            // US Tx Power card
            if let pwr = usPwr {
                let usStatus: (color: Color, headline: String, detail: String) = {
                    if pwr <= 46 {
                        return (.green,
                                "US Tx Power \(String(format: "%.1f", pwr)) dBmV — Normal",
                                "Within the comfortable upstream range (38–46 dBmV). The modem isn't working hard to reach the CMTS.")
                    } else if pwr <= 51 {
                        return (.yellow,
                                "US Tx Power \(String(format: "%.1f", pwr)) dBmV — Elevated",
                                "Above the comfortable range (38–46 dBmV) but within the DOCSIS spec limit (54 dBmV). Elevated TX power means the modem is compensating for signal loss between your home and the cable node. Common causes: corroded coax connector, bad splitter, aging drop cable, or the ISP node is overloaded. Worth checking your coax runs.")
                    } else {
                        return (.red,
                                "US Tx Power \(String(format: "%.1f", pwr)) dBmV — Critical",
                                "Approaching or exceeding the DOCSIS spec limit (54 dBmV). The modem is transmitting at near-maximum power and may trigger partial service mode or ranging failures. This requires ISP attention — likely a plant-side issue or failing drop cable.")
                    }
                }()
                CM3000ContextCard(color: usStatus.color, headline: usStatus.headline, detail: usStatus.detail)
            }

            // Uncorrectable codewords card (only show when non-zero)
            if uncorr > 0 {
                CM3000ContextCard(
                    color: .orange,
                    headline: "\(uncorr) Uncorrectable Codewords — Cumulative Since Boot",
                    detail: "Uncorrectable codewords are errors the modem cannot recover through error correction. This counter accumulates since the last reboot, so the absolute number matters less than the rate. \(uncorr) errors over a multi-day uptime may be low-rate background noise (e.g. a brief RF disturbance weeks ago). If you're seeing service interruptions, reset the counter by rebooting the modem and watch whether it climbs rapidly."
                )
            }
        }
    }

    // MARK: - Issue guidance (shown when actionable problems are detected)

    @ViewBuilder
    private func issueGuidanceSection(_ snap: ConnectorSnapshot) -> some View {
        let hasPartialService = snap.events.contains { $0.type == "partial_service" }
        let usPwr = snap.metrics.first(where: { $0.key == "avg_us_power" })?.value ?? 0
        let startupFailed = (snap.metrics.first(where: { $0.key == "startup_ok" })?.value ?? 1) == 0
        let hasActionableIssue = hasPartialService || usPwr > 46 || startupFailed

        if hasActionableIssue {
            VStack(alignment: .leading, spacing: 10) {
                Text("Guidance")
                    .font(.headline)

                if hasPartialService {
                    CM3000GuidanceCard(
                        icon: "exclamationmark.triangle.fill",
                        color: .red,
                        title: "Partial Service Mode Active",
                        steps: [
                            "One or more upstream channels have been taken offline by the CMTS (cable head-end). This is an ISP-side action, not a modem failure.",
                            "Check coaxial connections from wall outlet to modem — ensure they're finger-tight and not corroded.",
                            "If connections look good, this requires an ISP technician visit to inspect the drop cable and tap.",
                            "Document: note today's date, your modem's upstream TX power (\(String(format: "%.1f", usPwr)) dBmV), and any modem log messages."
                        ],
                        contactInfo: ispContactInfo
                    )
                }

                if usPwr > 51 {
                    CM3000GuidanceCard(
                        icon: "arrow.up.circle.fill",
                        color: .red,
                        title: "Upstream TX Power Critical",
                        steps: [
                            "Replace or bypass any coax splitters between the wall outlet and the CM3000.",
                            "Check the coax cable from wall to modem — ensure it's RG6, properly terminated, and undamaged.",
                            "Connect the CM3000 directly to the cable wall outlet (no splitter) to isolate the issue.",
                            "If TX power stays high with a direct connection, the problem is in the cable plant (ISP-side) — file a service ticket."
                        ],
                        contactInfo: ispContactInfo
                    )
                } else if usPwr > 46 {
                    CM3000GuidanceCard(
                        icon: "arrow.up.circle",
                        color: .orange,
                        title: "Upstream TX Power Elevated",
                        steps: [
                            "Check coax splitters — each passive splitter adds ~3.5 dB loss per leg. Eliminate unnecessary splits.",
                            "Inspect the coax connector at the modem — finger-tight F-connector, no corrosion.",
                            "Consider replacing the cable run from wall outlet to modem if it's old or kinked.",
                            "If TX power is trending upward over time, schedule a proactive ISP check."
                        ],
                        contactInfo: nil
                    )
                }

                if startupFailed {
                    CM3000GuidanceCard(
                        icon: "xmark.seal.fill",
                        color: .red,
                        title: "DOCSIS Initialization Failed",
                        steps: [
                            "Power cycle the CM3000: unplug for 30 seconds, then reconnect.",
                            "If the failure persists, check the modem's startup log in the Events tab.",
                            "A T4 Timeout or Registration Failed error indicates the CMTS cannot reach the modem reliably — ISP intervention required.",
                            "Verify the CM3000 is provisioned on your ISP account (modem MAC address must be registered)."
                        ],
                        contactInfo: ispContactInfo
                    )
                }
            }
        }
    }

    // MARK: - Channels tab

    @ViewBuilder
    private var channelsTab: some View {
        if let snap = snapshot {
            let dsScQam  = Int(snap.metrics.first(where: { $0.key == "ds_sc_qam" })?.value
                            ?? snap.metrics.first(where: { $0.key == "ds_channels" })?.value ?? 0)
            let dsOfdm   = Int(snap.metrics.first(where: { $0.key == "ds_ofdm" })?.value ?? 0)
            let usTotal  = Int(snap.metrics.first(where: { $0.key == "us_channels" })?.value ?? 0)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Downstream Channels")
                            .font(.headline)
                        if dsScQam > 0 {
                            Text("\(dsScQam) SC-QAM\(dsOfdm > 0 ? " + \(dsOfdm) OFDM" : "") bonded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Channel detail table header
                        channelTableHeader()

                        // Placeholder — per-channel data exposed by connector in a future sprint
                        Text("Per-channel breakdown requires the companion snapshot script to expose the raw channel arrays. Aggregate SNR and power metrics are shown in the Overview tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Upstream Channels")
                            .font(.headline)
                        Text("\(usTotal) SC-QAM bonded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 40)
                }
                .padding(20)
            }
        } else {
            Text("No channel data available")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func channelTableHeader() -> some View {
        HStack(spacing: 0) {
            Text("Ch").frame(width: 32, alignment: .leading)
            Text("Freq").frame(width: 80, alignment: .leading)
            Text("Mod").frame(width: 60, alignment: .leading)
            Text("SNR").frame(width: 72, alignment: .leading)
            Text("Power").frame(width: 72, alignment: .leading)
            Text("Corr").frame(width: 60, alignment: .trailing)
            Text("Uncorr").frame(width: 60, alignment: .trailing)
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)

    }

    // MARK: - Events tab

    @ViewBuilder
    private var eventsTab: some View {
        if let snap = snapshot, !snap.events.isEmpty {
            List {
                ForEach(Array(snap.events.prefix(40).enumerated()), id: \.offset) { _, event in
                    CM3000EventRow(event: event)
                }
            }
            .listStyle(.plain)
        } else {
            Text("No events recorded")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Unavailable state

    private var unavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("CM3000 data unavailable")
                .font(.headline)
            Text("The connector may be disabled or the modem unreachable.\nEnable the CM3000 connector in Settings → Connectors.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Helpers

    private func severityColor(_ sev: MetricSeverity?) -> Color {
        switch sev {
        case .ok:       return .green
        case .info:     return .blue
        case .warning:  return .yellow
        case .critical: return .red
        default:        return .secondary
        }
    }

    private var ispContactInfo: String {
        "Comcast Tech Support: 1-800-934-6489\nHave ready: account number, modem MAC address (on CM3000 label), and current date/time."
    }
}

// MARK: - CM3000 Tile

private struct CM3000Tile: View {
    let icon:  String
    let label: String
    let value: String
    let unit:  String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
    }
}

// MARK: - Context Card (educational callout)

private struct CM3000ContextCard: View {
    let color:    Color
    let headline: String
    let detail:   String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
                .cornerRadius(2)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.06))
        )
    }
}

// MARK: - Guidance Card (actionable steps)

private struct CM3000GuidanceCard: View {
    let icon:        String
    let color:       Color
    let title:       String
    let steps:       [String]
    let contactInfo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(step)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let contact = contactInfo {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("ISP Contact")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(contact)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Event Row

private struct CM3000EventRow: View {
    let event: ConnectorEvent

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(severityColor)
                .frame(width: 6, height: 6)
            Text(event.timestamp, style: .time)
                .font(.caption2).foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 60, alignment: .leading)
            Text(event.type.uppercased().replacingOccurrences(of: "_", with: " "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(event.description)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var severityColor: Color {
        switch event.severity {
        case .ok, .info: return .blue
        case .warning:   return .yellow
        case .critical:  return .red
        case .unknown:   return .secondary
        }
    }
}
