/// StackHealthView.swift — Cross-device stack health dashboard for NetWatch
///
/// Displays the output of StackDiagnosisEngine as a live, interactive panel:
///
///   • Health score gauge (0–100, colour-coded)
///   • Per-layer status table with evidence bullets
///   • Recommendations list
///   • "Run Diagnosis" button to force a fresh analysis
///
/// Data flow:
///   ConnectorsView (parent) → StackHealthView
///   The view reads ConnectorManager + NetworkMonitorService from EnvironmentObjects
///   and runs StackDiagnosisEngine synchronously on demand.

import SwiftUI

struct StackHealthView: View {

    @EnvironmentObject var connectorManager: ConnectorManager
    @EnvironmentObject var monitor:          NetworkMonitorService

    @State private var diagnosis: StackDiagnosis? = nil
    @State private var isRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                if let d = diagnosis {
                    scoreSection(d)
                    layerSection(d)
                    if !d.recommendations.isEmpty {
                        recommendationSection(d)
                    }
                } else {
                    emptyState
                }
                Spacer(minLength: 40)
            }
            .padding(20)
        }
        .onAppear { if diagnosis == nil { runDiagnosis() } }
        .onChange(of: connectorManager.snapshots.count) { _, _ in runDiagnosis() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stack Health").font(.headline)
                Text("Cross-device root-cause analysis")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = diagnosis {
                Text(d.timestamp, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                runDiagnosis()
            } label: {
                HStack(spacing: 4) {
                    if isRunning {
                        ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRunning ? "Running…" : "Run Diagnosis")
                        .font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRunning)
        }
    }

    @ViewBuilder
    private func scoreSection(_ d: StackDiagnosis) -> some View {
        GroupBox {
            HStack(spacing: 24) {
                // Health score gauge
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: CGFloat(d.healthScore) / 100.0)
                        .stroke(scoreColor(d.healthScore), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(d.healthScore)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(scoreColor(d.healthScore))
                        Text("/ 100").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: rootCauseIcon(d.rootCause))
                            .foregroundStyle(scoreColor(d.healthScore))
                        Text(d.summary)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if d.rootCause != .unknown {
                        HStack(spacing: 4) {
                            Text("Root cause:")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(d.rootCause.rawValue)
                                .font(.caption2.bold())
                            Text("·")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(d.confidence.rawValue) confidence")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func layerSection(_ d: StackDiagnosis) -> some View {
        GroupBox("Network Stack") {
            VStack(spacing: 0) {
                ForEach(d.layerResults, id: \.layer.rawValue) { lr in
                    LayerRow(result: lr, isRootCause: lr.layer == d.rootCause)
                    if lr.layer != d.layerResults.last?.layer {
                        Divider().padding(.leading, 24).opacity(0.4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recommendationSection(_ d: StackDiagnosis) -> some View {
        GroupBox("Recommendations") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(d.recommendations.enumerated()), id: \.offset) { _, rec in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                            .padding(.top, 1)
                        Text(rec)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "stethoscope")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Run a diagnosis to analyse your network stack")
                .foregroundStyle(.secondary)
            Button("Run Diagnosis Now") { runDiagnosis() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Logic

    private func runDiagnosis() {
        guard !isRunning else { return }
        isRunning = true
        // StackDiagnosisEngine is synchronous — dispatch off main briefly so the
        // "Running…" button label has time to appear, then update on main.
        Task {
            // Use the most recent traceroute result across all targets
            let traceroute = monitor.tracerouteMonitor.results.values.first
            let result = StackDiagnosisEngine.diagnose(
                pingStates:  monitor.pingStates,
                dnsStates:   monitor.dnsStates,
                traceroute:  traceroute,
                snapshots:   connectorManager.allSnapshots
            )
            await MainActor.run {
                diagnosis = result
                isRunning = false
            }
        }
    }

    // MARK: - Helpers

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 85...: return .green
        case 60..<85: return .yellow
        case 30..<60: return .orange
        default:      return .red
        }
    }

    private func rootCauseIcon(_ layer: StackLayer) -> String {
        switch layer {
        case .internet:  return "globe"
        case .isp:       return "antenna.radiowaves.left.and.right"
        case .modem:     return "cable.connector.horizontal"
        case .firewall:  return "shield.lefthalf.filled"
        case .mesh:      return "wifi.router"
        case .client:    return "laptopcomputer"
        case .unknown:   return "questionmark.circle"
        }
    }
}

// MARK: - Layer Row

private struct LayerRow: View {
    let result:      LayerResult
    let isRootCause: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    // Status dot
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle().stroke(isRootCause ? Color.orange : Color.clear, lineWidth: 2)
                                .frame(width: 12, height: 12)
                        )
                    Text(result.layer.rawValue)
                        .font(.callout)
                        .frame(width: 120, alignment: .leading)
                    Text(result.status.rawValue.capitalized)
                        .font(.caption).foregroundStyle(statusColor)
                    if isRootCause {
                        Text("← Root Cause")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                    Spacer()
                    // Mini score bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.2))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(statusColor.opacity(0.7))
                                .frame(width: geo.size.width * CGFloat(result.score) / 100)
                        }
                    }
                    .frame(width: 60, height: 6)
                    Text("\(result.score)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            if expanded && !result.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.evidence, id: \.self) { ev in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").font(.caption2).foregroundStyle(.secondary)
                            Text(ev).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 18)
                .padding(.bottom, 8)
            }
        }
    }

    private var statusColor: Color {
        switch result.status {
        case .healthy:  return .green
        case .degraded: return .yellow
        case .critical: return .red
        case .unknown:  return .secondary
        }
    }
}
