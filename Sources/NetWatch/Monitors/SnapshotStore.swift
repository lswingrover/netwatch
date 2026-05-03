/// SnapshotStore.swift — Rolling 7-day metric history + trend computation
///
/// Every ConnectorSnapshot produced by ConnectorManager is serialised into a
/// per-connector JSON file under ~/.netwatch/history/. Points older than the
/// retention window are pruned on each write. The store provides:
///
///   • history(for:metricKey:) — time-series [MetricDataPoint] for a connector metric
///   • trend(for:metricKey:)   — MetricTrend (direction, rate, sparkline)
///
/// Persistence format (one file per connector):
///   ~/.netwatch/history/<connectorId>.json
///   JSON array of PersistedSnapshot objects.
///
/// Threading: all public methods are safe to call from @MainActor context (they
/// are not themselves async — JSON I/O is synchronous but fast for the data
/// volumes involved; the largest expected file is ~2 MB for a 7-day window at
/// 30-second intervals).

import Foundation

// MARK: - Data types

/// A single timestamped metric value.
struct MetricDataPoint: Codable {
    let timestamp: Date
    let value:     Double
}

/// Direction a metric is trending over recent history.
enum TrendDirection: String {
    case rising  = "rising"
    case falling = "falling"
    case stable  = "stable"
}

/// Aggregated trend information for a single metric key over the history window.
struct MetricTrend {
    let metricKey:      String
    let connectorId:    String
    let dataPoints:     [MetricDataPoint]   ///< Ordered oldest→newest
    let direction:      TrendDirection
    let changePerHour:  Double              ///< Positive = rising, negative = falling
    let min:            Double
    let max:            Double
    let avg:            Double
    /// Values normalised 0–1 for sparkline rendering, oldest first.
    /// If all values are equal, all points are 0.5.
    let sparkline:      [Double]
    /// Span of data in hours.
    let spanHours:      Double

    var hasData: Bool { !dataPoints.isEmpty }
}

// MARK: - Persisted snapshot (compact on-disk format)

/// Compact representation of one ConnectorSnapshot for JSON storage.
/// Only numeric metric values are stored — string-only metrics (like IP addresses
/// stored as `unit`) are skipped since they can't be trended.
private struct PersistedSnapshot: Codable {
    let connectorId: String
    let timestamp:   Date
    /// Metric key → Double value pairs.
    let metrics:     [String: Double]

    init(from snapshot: ConnectorSnapshot) {
        connectorId = snapshot.connectorId
        timestamp   = snapshot.timestamp
        var m: [String: Double] = [:]
        for metric in snapshot.metrics where metric.value != 0 || metric.unit.isEmpty {
            m[metric.key] = metric.value
        }
        metrics = m
    }
}

// MARK: - SnapshotStore

@MainActor
final class SnapshotStore: ObservableObject {

    // MARK: - Config

    static let retentionDays: Double = 7.0
    private var retentionInterval: TimeInterval { Self.retentionDays * 86_400 }

    // MARK: - Storage directory

    private let historyDir: URL

    // MARK: - In-memory cache: connectorId → [PersistedSnapshot] newest first

    private var cache: [String: [PersistedSnapshot]] = [:]

    // MARK: - Init

    init(baseDir: String = "~/.netwatch/history") {
        let expanded = (baseDir as NSString).expandingTildeInPath
        historyDir = URL(fileURLWithPath: expanded)
        try? FileManager.default.createDirectory(at: historyDir,
                                                  withIntermediateDirectories: true)
        loadAll()
    }

    // MARK: - Public API

    /// Append a new connector snapshot to persistent storage.
    /// Old points outside the retention window are pruned automatically.
    func append(_ snapshot: ConnectorSnapshot) {
        let point = PersistedSnapshot(from: snapshot)
        let id    = snapshot.connectorId
        var existing = cache[id] ?? []
        existing.insert(point, at: 0)  // newest first
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        existing = existing.filter { $0.timestamp >= cutoff }
        cache[id] = existing
        persist(id: id, points: existing)
    }

    /// Returns time-series data points (oldest first) for a specific metric key
    /// on a given connector. Returns an empty array if no history exists.
    func history(for connectorId: String, metricKey: String) -> [MetricDataPoint] {
        let points = cache[connectorId] ?? []
        return points
            .compactMap { snap -> MetricDataPoint? in
                guard let v = snap.metrics[metricKey] else { return nil }
                return MetricDataPoint(timestamp: snap.timestamp, value: v)
            }
            .reversed()  // oldest first
    }

    /// Computes a full MetricTrend for the given metric on the given connector.
    /// Accepts an optional `windowHours` to limit the lookback (default: all data).
    func trend(for connectorId: String,
               metricKey: String,
               windowHours: Double? = nil) -> MetricTrend {
        var points = history(for: connectorId, metricKey: metricKey)

        if let wh = windowHours, !points.isEmpty {
            let cutoff = Date().addingTimeInterval(-wh * 3_600)
            points = points.filter { $0.timestamp >= cutoff }
        }

        guard !points.isEmpty else {
            return MetricTrend(
                metricKey: metricKey, connectorId: connectorId,
                dataPoints: [], direction: .stable, changePerHour: 0,
                min: 0, max: 0, avg: 0, sparkline: [], spanHours: 0)
        }

        let values   = points.map(\.value)
        let minVal   = values.min()!
        let maxVal   = values.max()!
        let avgVal   = values.reduce(0, +) / Double(values.count)

        // Trend direction via simple linear regression over time
        let (direction, ratePerHour) = linearTrend(points: points)

        // Sparkline: normalised 0-1
        let range = maxVal - minVal
        let sparkline: [Double]
        if range == 0 {
            sparkline = values.map { _ in 0.5 }
        } else {
            sparkline = values.map { ($0 - minVal) / range }
        }

        // Span
        let spanHours: Double
        if let first = points.first?.timestamp, let last = points.last?.timestamp {
            spanHours = last.timeIntervalSince(first) / 3_600
        } else {
            spanHours = 0
        }

        return MetricTrend(
            metricKey:     metricKey,
            connectorId:   connectorId,
            dataPoints:    points,
            direction:     direction,
            changePerHour: ratePerHour,
            min:           minVal,
            max:           maxVal,
            avg:           avgVal,
            sparkline:     sparkline,
            spanHours:     spanHours
        )
    }

    /// Returns a list of metric keys that have history for the given connector.
    func availableMetricKeys(for connectorId: String) -> [String] {
        guard let points = cache[connectorId], !points.isEmpty else { return [] }
        return Array(Set(points.flatMap { $0.metrics.keys })).sorted()
    }

    /// Returns all connector IDs that have at least one persisted point.
    var storedConnectorIds: [String] {
        Array(cache.keys).sorted()
    }

    /// Wipe all history for a connector.
    func clearHistory(for connectorId: String) {
        cache.removeValue(forKey: connectorId)
        let file = historyFile(for: connectorId)
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Disk I/O

    private func historyFile(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return historyDir.appendingPathComponent("\(safe).json")
    }

    private func loadAll() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: historyDir, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        for entry in entries where entry.pathExtension == "json" {
            guard let data   = try? Data(contentsOf: entry),
                  let points = try? decoder.decode([PersistedSnapshot].self, from: data),
                  let first  = points.first else { continue }
            cache[first.connectorId] = points
        }
    }

    private func persist(id: String, points: [PersistedSnapshot]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(points) else { return }
        try? data.write(to: historyFile(for: id), options: .atomic)
    }

    // MARK: - Linear trend

    /// Returns (direction, rate-per-hour) via ordinary least-squares regression
    /// over the time-series. Time is expressed in hours relative to the first point.
    private func linearTrend(points: [MetricDataPoint]) -> (TrendDirection, Double) {
        guard points.count >= 3 else { return (.stable, 0) }

        let t0 = points.first!.timestamp.timeIntervalSince1970
        var sumX  = 0.0, sumY  = 0.0
        var sumXY = 0.0, sumX2 = 0.0
        let n = Double(points.count)

        for p in points {
            let x = (p.timestamp.timeIntervalSince1970 - t0) / 3_600  // hours
            let y = p.value
            sumX  += x
            sumY  += y
            sumXY += x * y
            sumX2 += x * x
        }

        let denom = n * sumX2 - sumX * sumX
        guard abs(denom) > 1e-9 else { return (.stable, 0) }

        let slope = (n * sumXY - sumX * sumY) / denom  // value per hour

        // Stable if change over the full window is < 5% of mean (or < 0.01 absolute)
        let meanY  = sumY / n
        let totalX = (points.last!.timestamp.timeIntervalSince1970 - t0) / 3_600
        let totalChange = abs(slope * totalX)
        let threshold   = max(0.01, abs(meanY) * 0.05)

        let direction: TrendDirection
        if totalChange < threshold {
            direction = .stable
        } else {
            direction = slope > 0 ? .rising : .falling
        }
        return (direction, slope)
    }
}
