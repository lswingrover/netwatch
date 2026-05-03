/// ConnectorTimelineView.swift — Metric history + sparklines for a connector
///
/// Shows rolling 7-day history for all numeric metrics on a given connector,
/// sourced from SnapshotStore. Features:
///
///   • Metric selector sidebar: each key shows trend direction, current value
///   • Detail panel: sparkline chart + min/avg/max/trend rate statistics
///   • Time range selector: 1h / 6h / 24h / 7d
///
/// Integrated into ConnectorDetailView's "History" tab.

import SwiftUI
import Charts

struct ConnectorTimelineView: View {

    let connectorId: String
    @EnvironmentObject var connectorManager: ConnectorManager

    @State private var selectedKey:  String? = nil
    @State private var windowHours:  Double  = 24   // default 24h window

    private var store: SnapshotStore { connectorManager.snapshotStore }

    private var metricKeys: [String] {
        store.availableMetricKeys(for: connectorId)
            .filter { !$0.hasSuffix("_name") }   // skip string-only label metrics
    }

    var body: some View {
        if metricKeys.isEmpty {
            noDataState
        } else {
            HSplitView {
                // Metric list
                metricList
                    .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
                // Detail panel
                if let key = selectedKey {
                    metricDetail(key: key)
                } else {
                    selectPrompt
                }
            }
            .onAppear {
                if selectedKey == nil { selectedKey = metricKeys.first }
            }
        }
    }

    // MARK: - Metric List

    private var metricList: some View {
        VStack(spacing: 0) {
            // Time range picker
            Picker("Window", selection: $windowHours) {
                Text("1h").tag(Double(1))
                Text("6h").tag(Double(6))
                Text("24h").tag(Double(24))
                Text("7d").tag(Double(168))
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            List(metricKeys, id: \.self, selection: $selectedKey) { key in
                MetricTrendRow(
                    trend: store.trend(for: connectorId, metricKey: key, windowHours: windowHours),
                    windowHours: windowHours
                )
                .tag(key)
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Detail Panel

    @ViewBuilder
    private func metricDetail(key: String) -> some View {
        let trend = store.trend(for: connectorId, metricKey: key, windowHours: windowHours)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(humanLabel(key)).font(.headline)
                        Text(windowLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TrendBadge(direction: trend.direction, rate: trend.changePerHour, unit: unitForKey(key))
                }

                // Stats row
                if trend.hasData {
                    HStack(spacing: 0) {
                        StatPill(label: "Min",  value: formatValue(trend.min, key: key))
                        Divider().frame(height: 36)
                        StatPill(label: "Avg",  value: formatValue(trend.avg, key: key))
                        Divider().frame(height: 36)
                        StatPill(label: "Max",  value: formatValue(trend.max, key: key))
                        Divider().frame(height: 36)
                        StatPill(label: "Points", value: "\(trend.dataPoints.count)")
                    }
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor)))

                    // Sparkline chart (Charts framework)
                    GroupBox("History") {
                        MetricLineChart(dataPoints: trend.dataPoints, metricKey: key)
                            .frame(height: 160)
                    }
                } else {
                    Text("No data yet for this metric in the selected window.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }

                Spacer()
            }
            .padding(20)
        }
    }

    // MARK: - Supporting Views

    private var noDataState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.flattrend.xyaxis")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No history yet")
                .font(.headline).foregroundStyle(.secondary)
            Text("Metric history accumulates over time.\nData is stored for 7 days.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectPrompt: some View {
        Text("Select a metric to see its history")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var windowLabel: String {
        switch windowHours {
        case 1:   return "Last 1 hour"
        case 6:   return "Last 6 hours"
        case 24:  return "Last 24 hours"
        case 168: return "Last 7 days"
        default:  return "Last \(Int(windowHours)) hours"
        }
    }

    private func humanLabel(_ key: String) -> String {
        // Convert snake_case to Title Case
        key.components(separatedBy: "_")
           .map { $0.capitalized }
           .joined(separator: " ")
    }

    private func unitForKey(_ key: String) -> String {
        if key.hasSuffix("_h") || key.hasSuffix("_hours") { return "h" }
        if key.hasSuffix("_db") || key.hasSuffix("_snr") || key.hasSuffix("_dbmv") { return "dB" }
        if key.hasSuffix("_mb") || key.hasSuffix("_bytes") { return "MB" }
        if key.hasSuffix("_pct") || key.hasSuffix("_percent") { return "%" }
        return ""
    }

    private func formatValue(_ v: Double, key: String) -> String {
        let unit = unitForKey(key)
        switch unit {
        case "h":  return String(format: "%.1fh", v)
        case "dB": return String(format: "%.1f dB", v)
        case "MB": return String(format: "%.0f MB", v)
        case "%":  return String(format: "%.0f%%", v)
        default:   return String(format: v < 10 ? "%.2f" : "%.0f", v)
        }
    }
}

// MARK: - MetricTrendRow (sidebar list item)

private struct MetricTrendRow: View {
    let trend:       MetricTrend
    let windowHours: Double

    var body: some View {
        HStack(spacing: 8) {
            // Mini sparkline canvas
            MiniSparkline(values: trend.sparkline)
                .frame(width: 44, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(humanLabel(trend.metricKey))
                    .font(.caption)
                    .lineLimit(1)
                if trend.hasData {
                    Text(String(format: "%.1f  →  %.1f", trend.min, trend.max))
                        .font(.caption2).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            // Trend arrow
            Image(systemName: trendIcon(trend.direction))
                .font(.caption2)
                .foregroundStyle(trendColor(trend.direction))
        }
        .padding(.vertical, 2)
    }

    private func humanLabel(_ key: String) -> String {
        key.components(separatedBy: "_").map { $0.capitalized }.joined(separator: " ")
    }

    private func trendIcon(_ dir: TrendDirection) -> String {
        switch dir {
        case .rising:  return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .stable:  return "arrow.right"
        }
    }

    private func trendColor(_ dir: TrendDirection) -> Color {
        switch dir {
        case .rising:  return .orange
        case .falling: return .blue
        case .stable:  return .secondary
        }
    }
}

// MARK: - MiniSparkline (Canvas-based, no Charts dependency)

struct MiniSparkline: View {
    let values: [Double]   // normalised 0–1

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let w = size.width
            let h = size.height
            let step = w / CGFloat(values.count - 1)

            var path = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * step
                let y = h - CGFloat(v) * h
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else       { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(.blue.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - TrendBadge

struct TrendBadge: View {
    let direction:    TrendDirection
    let rate:         Double    // units per hour
    let unit:         String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(rateLabel).font(.caption2).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundStyle(color)
    }

    private var icon: String {
        switch direction {
        case .rising:  return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .stable:  return "minus"
        }
    }

    private var color: Color {
        switch direction {
        case .rising:  return .orange
        case .falling: return .blue
        case .stable:  return .secondary
        }
    }

    private var rateLabel: String {
        if direction == .stable { return "Stable" }
        let absRate = abs(rate)
        if absRate < 0.01 { return "Stable" }
        let sign = rate > 0 ? "+" : "−"
        if unit.isEmpty {
            return String(format: "%@%.1f/h", sign, absRate)
        }
        return String(format: "%@%.1f %@/h", sign, absRate, unit)
    }
}

// MARK: - StatPill

private struct StatPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.callout.bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - MetricLineChart

private struct MetricLineChart: View {
    let dataPoints: [MetricDataPoint]
    let metricKey:  String

    var body: some View {
        Chart {
            ForEach(Array(dataPoints.enumerated()), id: \.offset) { _, dp in
                LineMark(
                    x: .value("Time", dp.timestamp),
                    y: .value("Value", dp.value)
                )
                .foregroundStyle(.blue.gradient)
                .interpolationMethod(.catmullRom)
            }
            // Highlight min/max
            if let minPt = dataPoints.min(by: { $0.value < $1.value }) {
                PointMark(x: .value("Time", minPt.timestamp), y: .value("Value", minPt.value))
                    .foregroundStyle(.blue)
                    .symbolSize(30)
            }
            if let maxPt = dataPoints.max(by: { $0.value < $1.value }) {
                PointMark(x: .value("Time", maxPt.timestamp), y: .value("Value", maxPt.value))
                    .foregroundStyle(.orange)
                    .symbolSize(30)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: strideComponent, count: 4)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: axisFormat)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
    }

    private var spanHours: Double {
        guard let first = dataPoints.first?.timestamp,
              let last  = dataPoints.last?.timestamp else { return 1 }
        return last.timeIntervalSince(first) / 3_600
    }

    private var strideComponent: Calendar.Component {
        spanHours <= 2   ? .minute :
        spanHours <= 24  ? .hour :
                           .day
    }

    private var axisFormat: Date.FormatStyle {
        spanHours <= 2   ? .dateTime.hour().minute() :
        spanHours <= 24  ? .dateTime.hour() :
                           .dateTime.month().day()
    }
}
