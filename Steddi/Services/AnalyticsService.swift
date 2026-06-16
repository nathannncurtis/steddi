import Foundation
import SwiftData
import CoreLocation

// MARK: - Time Window

/// Analytics time range. Picker order matches `allCases`.
enum AnalyticsTimeWindow: String, CaseIterable, Identifiable {
    case fourWeeks
    case threeMonths
    case oneYear
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fourWeeks: return "4W"
        case .threeMonths: return "3M"
        case .oneYear: return "1Y"
        case .all: return "All"
        }
    }

    /// Inclusive lower bound for the window, or nil for `.all`.
    func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .fourWeeks: return calendar.date(byAdding: .day, value: -28, to: now)
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now)
        case .oneYear: return calendar.date(byAdding: .year, value: -1, to: now)
        case .all: return nil
        }
    }
}

// MARK: - Value Types

/// Lightweight, Sendable snapshot of a completed drive used by the pure
/// trend/aggregation math. Built from DriveRecord summary fields — never
/// from the GPS blob.
struct DriveSample: Sendable, Equatable {
    let startedAt: Date
    let durationSeconds: Double
    let trafficSeconds: Double

    var durationMinutes: Double { durationSeconds / 60 }
    var trafficMinutes: Double { trafficSeconds / 60 }
}

/// A human-readable trend with sentiment and supporting sparkline data.
struct TrendInsight: Identifiable, Equatable {
    enum Sentiment: Equatable {
        case better   // sage — things improved
        case worse    // warm red — things got slower
        case steady   // neutral — no significant change
    }

    let id: String
    let message: String
    let detail: String?
    let sentiment: Sentiment
    /// Magnitude in minutes for the badge (0 for steady insights).
    let magnitudeMinutes: Double
    /// Recent values (minutes) for the sparkline, oldest first.
    let sparkline: [Double]
}

/// One point of a per-drive speed-vs-time chart.
struct SpeedTrendPoint: Identifiable, Equatable, Sendable {
    let offsetSeconds: Double
    let speedMps: Double

    var id: Double { offsetSeconds }
    var speedMph: Double { speedMps * 2.23694 }
    var inTraffic: Bool { speedMps < DriveRecord.trafficSpeedThresholdMps }
}

/// Time-in-traffic for one drive, plotted over calendar time.
struct TrafficTimePoint: Identifiable, Equatable {
    let date: Date
    let trafficMinutes: Double
    let totalMinutes: Double

    var id: Date { date }
}

/// Window-level aggregate statistics for the stat cards and weekday chart.
struct AggregateStats: Equatable {
    let driveCount: Int
    let totalDrivingSeconds: Double
    let totalTrafficSeconds: Double
    let averageDurationSeconds: Double
    let medianDurationSeconds: Double
    let p90DurationSeconds: Double
    let weekdayAverages: [WeekdayAverage]

    var totalDrivingHours: Double { totalDrivingSeconds / 3600 }
    var totalTrafficHours: Double { totalTrafficSeconds / 3600 }
    var averageDurationMinutes: Double { averageDurationSeconds / 60 }
    var medianDurationMinutes: Double { medianDurationSeconds / 60 }
    var p90DurationMinutes: Double { p90DurationSeconds / 60 }

    static let empty = AggregateStats(
        driveCount: 0, totalDrivingSeconds: 0, totalTrafficSeconds: 0,
        averageDurationSeconds: 0, medianDurationSeconds: 0,
        p90DurationSeconds: 0, weekdayAverages: []
    )
}

/// Average drive duration for one weekday. `weekdayIndex` 0 = Sunday.
struct WeekdayAverage: Identifiable, Equatable {
    let weekdayIndex: Int
    let label: String
    let averageMinutes: Double
    let driveCount: Int

    var id: Int { weekdayIndex }
}

/// Sendable snapshot of one DriveRecord, captured on the MainActor before
/// the heavy GPS-blob decode is handed to a detached, off-main task. Holds
/// only value types (the GPS array is a Codable struct array), so it crosses
/// the actor boundary without touching the non-Sendable @Model off-actor.
struct DriveRecordSnapshot: Sendable {
    let id: UUID
    let title: String
    let startedAt: Date
    let durationSeconds: Double
    let trafficSeconds: Double
    let maxSpeedMps: Double?
    let averageSpeedMps: Double?
    let points: [GPSPoint]
}

/// Everything DriveDetailView needs, built once from a single record's GPS
/// blob (the only place the blob is decoded) and discarded on dismissal.
struct DriveDetail: Sendable {
    struct RouteSample: Sendable {
        let coordinate: CLLocationCoordinate2D
        let speedMps: Double
    }

    let id: UUID
    let title: String
    let startedAt: Date
    let durationSeconds: Double
    let trafficSeconds: Double
    let maxSpeedMps: Double?
    let averageSpeedMps: Double?
    /// Resampled speed-vs-time points (bounded count).
    let speedPoints: [SpeedTrendPoint]
    /// Offset ranges (seconds) where the drive was stopped/crawling —
    /// rendered as shading behind the speed chart.
    let trafficRanges: [ClosedRange<Double>]
    /// Simplified route trace with per-point speed for the colored polyline.
    let routeSamples: [RouteSample]
}

// MARK: - Analytics Service

/// Drives the analytics screens. Aggregation reads DriveRecord summary
/// fields (computed on write) and the CommuteAnalyticsAggregate cache —
/// the raw GPS blob is only decoded for a single drive in the detail view,
/// or once per legacy record during backfill.
@Observable
@MainActor
final class AnalyticsService {

    private(set) var aggregateStats: AggregateStats = .empty
    private(set) var trendInsights: [TrendInsight] = []
    private(set) var trafficTimeData: [TrafficTimePoint] = []
    private(set) var recentDrives: [DriveRecord] = []
    private(set) var isLoading = false
    /// Shown in place of trends when the window has too little data.
    private(set) var trendGateMessage: String?

    /// The window/clock AND the view's `ModelContext` the most recent load ran
    /// with, so a background backfill can re-aggregate into the SAME context the
    /// view owns once it finishes draining legacy records — keeping `recentDrives`
    /// bound to the view's context rather than a throwaway one. MainActor-isolated
    /// and only ever read/written on the MainActor, so holding the (non-Sendable)
    /// context here never crosses an actor boundary.
    private var lastLoad: (window: AnalyticsTimeWindow, context: ModelContext, now: Date)?
    /// Guards against spawning overlapping backfill passes when loadAnalytics is
    /// called repeatedly (appear + window changes) before the first one drains.
    private var backfillInFlight = false
    /// Guards against spawning overlapping weekly-aggregate rebuilds when the
    /// 1Y/All window is (re)loaded repeatedly before a rebuild finishes.
    private var rebuildInFlight = false

    /// How many drives the list section shows.
    static let recentDriveLimit = 50
    /// Regression and traffic charts operate on at most this many recent
    /// drives, regardless of window size.
    nonisolated static let trendSampleLimit = 120
    /// Time-in-traffic chart caps at this many bars.
    nonisolated static let trafficChartLimit = 60
    /// Drives longer than this are recording glitches, not commutes.
    nonisolated static let maxPlausibleDurationSeconds: Double = 5 * 3600

    // MARK: Loading

    /// Loads stats, trends, and the recent-drive list for a window.
    ///
    /// Small windows (4w/3m) aggregate raw summary fields directly — a
    /// bounded, scalar-only fetch. Large windows (1y/all) go cache-first
    /// through CommuteAnalyticsAggregate weekly buckets, rebuilding only
    /// buckets that are stale or whose drive count changed.
    func loadAnalytics(window: AnalyticsTimeWindow, context: ModelContext, now: Date = Date()) {
        isLoading = true
        defer { isLoading = false }

        lastLoad = (window, context, now)
        aggregate(window: window, context: context, now: now)

        // Legacy records (saved before the summary fields existed) decode their
        // entire GPS blob to backfill summaries — far too heavy for the MainActor
        // on the hottest analytics path. Drain that batch on a background context
        // and re-aggregate when it lands, so the first paint is never blocked.
        scheduleBackfill(container: context.container)
    }

    /// Builds and publishes every window aggregate from the cached summary
    /// fields. Pure with respect to the GPS blob — never decodes it.
    private func aggregate(window: AnalyticsTimeWindow, context: ModelContext, now: Date) {
        let calendar = Calendar.current
        let windowStart = window.startDate(now: now, calendar: calendar)

        switch window {
        case .fourWeeks, .threeMonths:
            let samples = Self.fetchSamples(context: context, from: windowStart)
            aggregateStats = Self.computeAggregateStats(samples: samples, calendar: calendar)
            trafficTimeData = Self.buildTrafficChart(samples: Array(samples.suffix(Self.trafficChartLimit)))
            applyTrends(Self.computeTrends(samples: samples, now: now, calendar: calendar))

        case .oneYear, .all:
            // The weekly-aggregate rebuild does an unbounded historical fetch +
            // context.save() — too heavy for the MainActor on the hottest
            // analytics path. When the cache is stale, drain the rebuild on a
            // background ModelContext and re-aggregate when it lands (mirrors
            // scheduleBackfill); paint cache-first NOW with whatever buckets
            // already exist so the first frame is never blocked. The cache-first
            // read self-corrects once the background rebuild re-aggregates.
            if Self.aggregatesNeedRebuild(context: context, now: now, calendar: calendar) {
                scheduleRebuild(container: context.container)
            }
            aggregateStats = Self.cacheFirstStats(
                context: context, windowStart: windowStart, now: now, calendar: calendar
            )
            let trendSamples = Self.fetchSamples(
                context: context, from: windowStart, newestFirstLimit: Self.trendSampleLimit
            )
            trafficTimeData = Self.buildTrafficChart(samples: Array(trendSamples.suffix(Self.trafficChartLimit)))
            applyTrends(Self.computeTrends(samples: trendSamples, now: now, calendar: calendar))
        }

        recentDrives = fetchRecentDrives(from: windowStart, context: context)
    }

    /// Drains the legacy-summary backfill on a detached background context, then
    /// re-aggregates the current window on the MainActor if any record was
    /// finalized. At most one pass runs at a time; if more legacy records remain
    /// after a full batch, another pass is queued so the backlog drains across a
    /// few cycles without ever touching the main thread.
    private func scheduleBackfill(container: ModelContainer) {
        guard !backfillInFlight else { return }
        backfillInFlight = true

        Task.detached(priority: .utility) {
            let backfilled = Self.backfillMissingSummaries(container: container)

            await MainActor.run {
                self.backfillInFlight = false
                guard backfilled > 0, let last = self.lastLoad else { return }
                // Newly-finalized records now qualify for aggregation. Re-aggregate
                // into the SAME context the view passed to `loadAnalytics` (stashed
                // in `lastLoad`), so `recentDrives` stays bound to the view's
                // context — not a throwaway one a detail/edit/delete flow would then
                // read from a different context than the rest of the app. Safe to
                // reuse here: this block runs on the MainActor, the same actor that
                // wrote `lastLoad`, so the non-Sendable context never crosses actors.
                self.aggregate(window: last.window, context: last.context, now: last.now)
                // A full batch likely means more legacy records remain — keep
                // draining until the backlog is empty.
                if backfilled >= Self.backfillBatchSize {
                    self.scheduleBackfill(container: container)
                }
            }
        }
    }

    /// Rebuilds the stale weekly aggregate buckets on a detached background
    /// context, then re-aggregates the current window on the MainActor so the
    /// cache-first stats pick up the freshly-written buckets. At most one
    /// rebuild runs at a time; repeated 1Y/All loads while one is in flight are
    /// coalesced. The heavy unbounded fetch + save never touches the main thread.
    private func scheduleRebuild(container: ModelContainer) {
        guard !rebuildInFlight else { return }
        rebuildInFlight = true

        // Pin the rebuild clock to the load that triggered it, so the open-week
        // boundary the background rebuild uses matches the cache-first read.
        let clock = lastLoad?.now ?? Date()
        Task.detached(priority: .utility) {
            // Fresh background context on the same container — NOT the view's
            // MainActor context — so the unbounded historical fetch + save runs
            // entirely off the main thread. Mirrors backfillMissingSummaries.
            let ctx = ModelContext(container)
            Self.rebuildAggregates(context: ctx, now: clock)

            await MainActor.run {
                self.rebuildInFlight = false
                guard let last = self.lastLoad else { return }
                // Re-aggregate into the SAME context the view passed to
                // loadAnalytics (stashed in lastLoad), which now sees the buckets
                // persisted by the background context. Safe to reuse the
                // non-Sendable context here: this block runs on the MainActor, the
                // same actor that wrote lastLoad, so it never crosses actors.
                self.aggregate(window: last.window, context: last.context, now: last.now)
            }
        }
    }

    private func applyTrends(_ result: (insights: [TrendInsight], gateMessage: String?)) {
        trendInsights = result.insights
        trendGateMessage = result.gateMessage
    }

    /// Captures everything `buildDriveDetail` needs from a (non-Sendable)
    /// DriveRecord into a Sendable snapshot. MUST run on the MainActor — it
    /// faults the GPS blob and the `associatedCommute` relationship — so the
    /// detached decode never touches the @Model off-actor.
    @MainActor
    static func snapshot(of record: DriveRecord) -> DriveRecordSnapshot {
        DriveRecordSnapshot(
            id: record.id,
            title: record.associatedCommute?.name ?? "Drive",
            startedAt: record.startedAt,
            durationSeconds: record.totalDurationSeconds
                ?? record.endedAt.map { $0.timeIntervalSince(record.startedAt) } ?? 0,
            trafficSeconds: record.trafficDurationSeconds ?? 0,
            maxSpeedMps: record.maxSpeedMps,
            averageSpeedMps: record.averageSpeedMps,
            points: record.rawGPSPoints
        )
    }

    /// Builds the detail payload for one drive from a Sendable snapshot. The
    /// only code path that decodes a GPS blob on behalf of the UI — heavy
    /// (resamples the full trace twice), so callers run it OFF the MainActor
    /// (see DriveDetailView.task) on the snapshot captured by `snapshot(of:)`.
    nonisolated static func buildDriveDetail(from snapshot: DriveRecordSnapshot) -> DriveDetail {
        let speedPoints = buildSpeedChart(points: snapshot.points)
        return DriveDetail(
            id: snapshot.id,
            title: snapshot.title,
            startedAt: snapshot.startedAt,
            durationSeconds: snapshot.durationSeconds,
            trafficSeconds: snapshot.trafficSeconds,
            maxSpeedMps: snapshot.maxSpeedMps,
            averageSpeedMps: snapshot.averageSpeedMps,
            speedPoints: speedPoints,
            trafficRanges: trafficRanges(in: speedPoints),
            routeSamples: buildRouteSamples(points: snapshot.points)
        )
    }

    // MARK: - Pure Math (nonisolated, testable)

    /// Window aggregates from drive samples. Outliers already filtered.
    nonisolated static func computeAggregateStats(samples: [DriveSample], calendar: Calendar = .current) -> AggregateStats {
        guard !samples.isEmpty else { return .empty }

        let durations = samples.map(\.durationSeconds).sorted()
        let totalDriving = durations.reduce(0, +)
        let totalTraffic = samples.map(\.trafficSeconds).reduce(0, +)

        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var sums = Array(repeating: 0.0, count: 7)
        var counts = Array(repeating: 0, count: 7)
        for sample in samples {
            let weekday = calendar.component(.weekday, from: sample.startedAt) - 1
            sums[weekday] += sample.durationSeconds
            counts[weekday] += 1
        }
        let weekdayAverages: [WeekdayAverage] = (0..<7).compactMap { idx in
            guard counts[idx] > 0 else { return nil }
            return WeekdayAverage(
                weekdayIndex: idx,
                label: dayNames[idx],
                averageMinutes: sums[idx] / Double(counts[idx]) / 60,
                driveCount: counts[idx]
            )
        }

        return AggregateStats(
            driveCount: samples.count,
            totalDrivingSeconds: totalDriving,
            totalTrafficSeconds: totalTraffic,
            averageDurationSeconds: totalDriving / Double(samples.count),
            medianDurationSeconds: percentile(sorted: durations, 0.5),
            p90DurationSeconds: percentile(sorted: durations, 0.9),
            weekdayAverages: weekdayAverages
        )
    }

    /// Minimum drives in the window before any trend is computed.
    nonisolated static let minDrivesForTrends = 6
    /// Minimum span between first and last drive before trends mean anything.
    nonisolated static let minSpanDaysForTrends = 14.0
    /// Per-weekday comparison needs this many drives in each half.
    nonisolated static let minDrivesPerWeekdayHalf = 3
    /// Weekday deltas below this many minutes are noise, not insight.
    nonisolated static let weekdayDeltaThresholdMinutes = 3.0
    /// Overall slope below this (minutes/week) reads as steady.
    nonisolated static let slopeThresholdMinutesPerWeek = 1.5

    /// Trend computation. Pure: given the same samples and clock it always
    /// returns the same insights. Returns a gate message instead of trends
    /// when the data can't honestly support them.
    nonisolated static func computeTrends(
        samples: [DriveSample],
        now: Date,
        calendar: Calendar = .current
    ) -> (insights: [TrendInsight], gateMessage: String?) {
        let valid = samples
            .filter { $0.durationSeconds > 0 && $0.durationSeconds <= maxPlausibleDurationSeconds }
            .sorted { $0.startedAt < $1.startedAt }

        guard valid.count >= minDrivesForTrends,
              let first = valid.first, let last = valid.last,
              last.startedAt.timeIntervalSince(first.startedAt) >= minSpanDaysForTrends * 86400
        else {
            return ([], "Trends unlock after about two weeks of drives. Keep going — every drive sharpens the picture.")
        }

        var insights: [TrendInsight] = []

        // Overall direction: linear regression of duration over time.
        let xs = valid.map { $0.startedAt.timeIntervalSince(first.startedAt) / 86400 } // days
        let ys = valid.map(\.durationMinutes)
        if let slopePerDay = linearRegressionSlope(xs: xs, ys: ys) {
            let slopePerWeek = slopePerDay * 7
            let sparkline = Array(ys.suffix(12))
            if abs(slopePerWeek) >= slopeThresholdMinutesPerWeek {
                let worse = slopePerWeek > 0
                insights.append(TrendInsight(
                    id: "overall-slope",
                    message: worse
                        ? "Commutes are trending slower"
                        : "Commutes are trending faster",
                    detail: String(format: "About %.0f min per week %@ across %d drives", abs(slopePerWeek), worse ? "longer" : "shorter", valid.count),
                    sentiment: worse ? .worse : .better,
                    magnitudeMinutes: abs(slopePerWeek),
                    sparkline: sparkline
                ))
            } else {
                insights.append(TrendInsight(
                    id: "overall-steady",
                    message: "Your commute is steady",
                    detail: "No significant change across \(valid.count) drives",
                    sentiment: .steady,
                    magnitudeMinutes: 0,
                    sparkline: sparkline
                ))
            }
        }

        // Weekday-over-weekday: compare the earlier half of each weekday's
        // drives against the later half.
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        var byWeekday: [Int: [DriveSample]] = [:]
        for sample in valid {
            let weekday = calendar.component(.weekday, from: sample.startedAt) - 1
            byWeekday[weekday, default: []].append(sample)
        }

        var weekdayInsights: [(delta: Double, insight: TrendInsight)] = []
        for (weekday, daySamples) in byWeekday {
            let half = daySamples.count / 2
            guard half >= minDrivesPerWeekdayHalf else { continue }
            let earlier = daySamples.prefix(half)
            let later = daySamples.suffix(daySamples.count - half)
            let earlierAvg = earlier.map(\.durationMinutes).reduce(0, +) / Double(earlier.count)
            let laterAvg = later.map(\.durationMinutes).reduce(0, +) / Double(later.count)
            let delta = laterAvg - earlierAvg
            guard abs(delta) >= weekdayDeltaThresholdMinutes else { continue }

            let worse = delta > 0
            let name = dayNames[weekday]
            weekdayInsights.append((abs(delta), TrendInsight(
                id: "weekday-\(weekday)",
                message: String(format: "%@ drives are %.0f min %@", name, abs(delta), worse ? "slower" : "faster"),
                detail: "Compared with your earlier \(name) drives in this period",
                sentiment: worse ? .worse : .better,
                magnitudeMinutes: abs(delta),
                sparkline: daySamples.suffix(10).map(\.durationMinutes)
            )))
        }
        // Biggest movers first; cap so the screen stays scannable.
        insights.append(contentsOf: weekdayInsights.sorted { $0.delta > $1.delta }.prefix(3).map(\.insight))

        // Traffic share trend, only when traffic is a real slice of the drive.
        let trafficShares = valid.map { $0.durationSeconds > 0 ? $0.trafficSeconds / $0.durationSeconds : 0 }
        if let trafficSlopePerDay = linearRegressionSlope(xs: xs, ys: trafficShares) {
            let sharePerWeek = trafficSlopePerDay * 7
            let avgShare = trafficShares.reduce(0, +) / Double(trafficShares.count)
            if abs(sharePerWeek) >= 0.03, avgShare >= 0.05 {
                let worse = sharePerWeek > 0
                insights.append(TrendInsight(
                    id: "traffic-share",
                    message: worse ? "More of your drive is spent in traffic" : "Less of your drive is spent in traffic",
                    detail: String(format: "Time stopped or crawling is %@ about %.0f%% per week", worse ? "up" : "down", abs(sharePerWeek) * 100),
                    sentiment: worse ? .worse : .better,
                    magnitudeMinutes: abs(sharePerWeek) * (valid.map(\.durationMinutes).reduce(0, +) / Double(valid.count)),
                    sparkline: valid.suffix(12).map(\.trafficMinutes)
                ))
            }
        }

        return (insights, nil)
    }

    /// Ordinary least-squares slope. Returns nil when the inputs are
    /// degenerate (fewer than 2 points or zero x-variance).
    nonisolated static func linearRegressionSlope(xs: [Double], ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    /// Linear-interpolated percentile of a pre-sorted array.
    nonisolated static func percentile(sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    /// Converts a raw GPS trace into a bounded speed-vs-time series by
    /// averaging into uniform time buckets. Keeps charts smooth and cheap
    /// regardless of trace length.
    nonisolated static func buildSpeedChart(points: [GPSPoint], maxPoints: Int = 160) -> [SpeedTrendPoint] {
        let valid = points.filter { $0.speed >= 0 && $0.speed <= DriveRecord.maxPlausibleSpeedMps }
        guard let firstTime = valid.first?.timestamp, let lastTime = valid.last?.timestamp, valid.count >= 2 else {
            return []
        }
        let span = lastTime.timeIntervalSince(firstTime)
        guard span > 0 else { return [] }

        if valid.count <= maxPoints {
            return valid.map {
                SpeedTrendPoint(offsetSeconds: $0.timestamp.timeIntervalSince(firstTime), speedMps: $0.speed)
            }
        }

        let bucketDuration = span / Double(maxPoints)
        var sums = Array(repeating: 0.0, count: maxPoints)
        var counts = Array(repeating: 0, count: maxPoints)
        for point in valid {
            let offset = point.timestamp.timeIntervalSince(firstTime)
            // firstTime/lastTime come from valid.first/.last, which are NOT
            // guaranteed to be the chronological extremes: out-of-order or
            // clock-adjusted GPS can yield a timestamp earlier than firstTime
            // (negative offset → negative index) or later than lastTime (index
            // past the end). An unclamped Int(offset / bucketDuration) would
            // then crash on subscript. Clamp into [0, maxPoints - 1] so a
            // stray sample lands in the nearest edge bucket instead of crashing.
            let rawBucket = Int((offset / bucketDuration).rounded(.down))
            let bucket = min(maxPoints - 1, max(0, rawBucket))
            sums[bucket] += point.speed
            counts[bucket] += 1
        }
        return (0..<maxPoints).compactMap { idx in
            guard counts[idx] > 0 else { return nil }
            return SpeedTrendPoint(
                offsetSeconds: (Double(idx) + 0.5) * bucketDuration,
                speedMps: sums[idx] / Double(counts[idx])
            )
        }
    }

    /// Time-in-traffic per drive over calendar time, oldest first.
    nonisolated static func buildTrafficChart(samples: [DriveSample]) -> [TrafficTimePoint] {
        samples
            .sorted { $0.startedAt < $1.startedAt }
            .map { TrafficTimePoint(date: $0.startedAt, trafficMinutes: $0.trafficMinutes, totalMinutes: $0.durationMinutes) }
    }

    /// Contiguous offset ranges where the chart shows traffic-speed travel.
    nonisolated static func trafficRanges(in points: [SpeedTrendPoint]) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var start: Double?
        var lastOffset: Double = 0
        for point in points {
            if point.inTraffic {
                if start == nil { start = point.offsetSeconds }
                lastOffset = point.offsetSeconds
            } else if let s = start {
                ranges.append(s...max(s, lastOffset))
                start = nil
            }
        }
        if let s = start {
            ranges.append(s...max(s, lastOffset))
        }
        return ranges
    }

    /// Simplified route trace (bounded count) with per-point speed for the
    /// speed-colored map polyline.
    nonisolated static func buildRouteSamples(points: [GPSPoint], maxPoints: Int = 300) -> [DriveDetail.RouteSample] {
        let valid = points.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 50 }
        guard valid.count > 1 else { return [] }
        if valid.count <= maxPoints {
            return valid.map { DriveDetail.RouteSample(coordinate: $0.coordinate, speedMps: max(0, $0.speed)) }
        }
        // `maxPoints < 2` would make the stride below divide by zero. Clamp to a
        // single endpoint sample rather than crash on a degenerate cap.
        guard maxPoints >= 2 else {
            return valid.prefix(1).map { DriveDetail.RouteSample(coordinate: $0.coordinate, speedMps: max(0, $0.speed)) }
        }
        let step = Double(valid.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { i in
            let point = valid[min(valid.count - 1, Int((Double(i) * step).rounded()))]
            return DriveDetail.RouteSample(coordinate: point.coordinate, speedMps: max(0, point.speed))
        }
    }

    // MARK: - Lazy Aggregation (cache-first)

    /// Start of the calendar week containing `date`.
    nonisolated static func weekStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// Cheap invalidation check: any stale bucket, or a closed-week drive
    /// count that no longer matches the cached buckets (drives added or
    /// deleted). Uses fetchCount — no records are materialized.
    nonisolated static func aggregatesNeedRebuild(
        context: ModelContext, now: Date, calendar: Calendar
    ) -> Bool {
        let buckets = (try? context.fetch(FetchDescriptor<CommuteAnalyticsAggregate>())) ?? []
        if buckets.contains(where: { $0.isStale(asOf: now) }) { return true }

        let currentWeekStart = weekStart(for: now, calendar: calendar)
        let maxDuration = maxPlausibleDurationSeconds
        let descriptor = FetchDescriptor<DriveRecord>(
            predicate: #Predicate {
                $0.startedAt < currentWeekStart &&
                ($0.totalDurationSeconds ?? 0) > 0 &&
                ($0.totalDurationSeconds ?? 0) <= maxDuration
            }
        )
        let closedWeekCount = (try? context.fetchCount(descriptor)) ?? 0
        return closedWeekCount != buckets.reduce(0) { $0 + $1.driveCount }
    }

    /// Rebuilds the weekly aggregate buckets for every closed week.
    /// Buckets that are current (same drive count, not stale) are left
    /// untouched; weeks with no remaining drives lose their bucket.
    /// The open (current) week is never cached — it's always live.
    nonisolated static func rebuildAggregates(
        context: ModelContext, now: Date = Date(), calendar: Calendar = .current
    ) {
        let currentWeekStart = weekStart(for: now, calendar: calendar)
        let samples = fetchSamples(context: context, from: nil, to: currentWeekStart)

        var byWeek: [Date: [DriveSample]] = [:]
        for sample in samples {
            byWeek[weekStart(for: sample.startedAt, calendar: calendar), default: []].append(sample)
        }

        let existing = (try? context.fetch(FetchDescriptor<CommuteAnalyticsAggregate>())) ?? []
        var existingByWeek: [Date: CommuteAnalyticsAggregate] = [:]
        for bucket in existing {
            // Duplicate or out-of-range buckets are corruption — drop them.
            if existingByWeek[bucket.weekStart] != nil || bucket.weekStart >= currentWeekStart {
                context.delete(bucket)
            } else {
                existingByWeek[bucket.weekStart] = bucket
            }
        }

        for (week, weekSamples) in byWeek {
            if let bucket = existingByWeek.removeValue(forKey: week) {
                if bucket.driveCount == weekSamples.count, !bucket.isStale(asOf: now) { continue }
                populate(bucket, with: weekSamples, calendar: calendar, now: now)
            } else {
                let bucket = CommuteAnalyticsAggregate(weekStart: week)
                populate(bucket, with: weekSamples, calendar: calendar, now: now)
                context.insert(bucket)
            }
        }

        // Whatever remains covers weeks that no longer have any drives.
        for orphan in existingByWeek.values {
            context.delete(orphan)
        }

        try? context.save()
    }

    /// Fills one weekly bucket from its samples.
    nonisolated private static func populate(
        _ bucket: CommuteAnalyticsAggregate,
        with samples: [DriveSample],
        calendar: Calendar,
        now: Date
    ) {
        let stats = computeAggregateStats(samples: samples, calendar: calendar)
        bucket.driveCount = stats.driveCount
        bucket.totalDrivingSeconds = stats.totalDrivingSeconds
        bucket.totalTrafficSeconds = stats.totalTrafficSeconds
        bucket.averageDurationSeconds = stats.averageDurationSeconds
        bucket.medianDurationSeconds = stats.medianDurationSeconds
        bucket.p90DurationSeconds = stats.p90DurationSeconds
        var sums = Array(repeating: 0.0, count: 7)
        var counts = Array(repeating: 0, count: 7)
        for sample in samples {
            let weekday = calendar.component(.weekday, from: sample.startedAt) - 1
            sums[weekday] += sample.durationSeconds
            counts[weekday] += 1
        }
        bucket.weekdayDurationSums = sums
        bucket.weekdayDriveCounts = counts
        bucket.generatedAt = now
    }

    /// Window stats assembled cache-first: cached buckets for fully-covered
    /// closed weeks, plus raw samples for the partial week at the window's
    /// start edge and the open current week.
    nonisolated static func cacheFirstStats(
        context: ModelContext, windowStart: Date?, now: Date, calendar: Calendar
    ) -> AggregateStats {
        let currentWeekStart = weekStart(for: now, calendar: calendar)

        // First week fully inside the window.
        var firstBucketWeek = Date.distantPast
        var headSamples: [DriveSample] = []
        if let windowStart {
            let startWeek = weekStart(for: windowStart, calendar: calendar)
            if startWeek == windowStart {
                firstBucketWeek = startWeek
            } else {
                firstBucketWeek = calendar.date(byAdding: .day, value: 7, to: startWeek) ?? startWeek
                headSamples = fetchSamples(context: context, from: windowStart, to: min(firstBucketWeek, currentWeekStart))
            }
        }

        let lower = firstBucketWeek
        let bucketDescriptor = FetchDescriptor<CommuteAnalyticsAggregate>(
            predicate: #Predicate { $0.weekStart >= lower && $0.weekStart < currentWeekStart },
            sortBy: [SortDescriptor(\.weekStart)]
        )
        let buckets = (try? context.fetch(bucketDescriptor)) ?? []

        let openSamples = fetchSamples(context: context, from: max(currentWeekStart, windowStart ?? .distantPast))
        return mergeAggregates(buckets, looseSamples: headSamples + openSamples, calendar: calendar)
    }

    /// Merges cached weekly buckets with un-cached samples into window
    /// stats. Counts, totals, averages, and weekday breakdowns merge
    /// exactly; median/p90 are weighted estimates from the per-week
    /// percentiles (exact when a single source dominates).
    nonisolated static func mergeAggregates(
        _ buckets: [CommuteAnalyticsAggregate],
        looseSamples: [DriveSample],
        calendar: Calendar = .current
    ) -> AggregateStats {
        guard !buckets.isEmpty else {
            return computeAggregateStats(samples: looseSamples, calendar: calendar)
        }

        var driveCount = looseSamples.count
        var totalDriving = looseSamples.map(\.durationSeconds).reduce(0, +)
        var totalTraffic = looseSamples.map(\.trafficSeconds).reduce(0, +)
        var sums = Array(repeating: 0.0, count: 7)
        var counts = Array(repeating: 0, count: 7)
        for sample in looseSamples {
            let weekday = calendar.component(.weekday, from: sample.startedAt) - 1
            sums[weekday] += sample.durationSeconds
            counts[weekday] += 1
        }

        var medianPairs: [(value: Double, weight: Double)] = looseSamples.map { ($0.durationSeconds, 1) }
        var p90Pairs = medianPairs

        for bucket in buckets {
            driveCount += bucket.driveCount
            totalDriving += bucket.totalDrivingSeconds
            totalTraffic += bucket.totalTrafficSeconds
            // Both weekday arrays are indexed with the same `idx`; if a corrupt
            // bucket has mismatched lengths, indexing the shorter one with the
            // longer's count would crash. Only iterate over the range valid for
            // BOTH arrays so a malformed bucket is partially-merged at worst,
            // never fatal.
            let weekdayCount = min(7, bucket.weekdayDurationSums.count, bucket.weekdayDriveCounts.count)
            for idx in 0..<weekdayCount {
                sums[idx] += bucket.weekdayDurationSums[idx]
                counts[idx] += bucket.weekdayDriveCounts[idx]
            }
            if bucket.driveCount > 0 {
                medianPairs.append((bucket.medianDurationSeconds, Double(bucket.driveCount)))
                p90Pairs.append((bucket.p90DurationSeconds, Double(bucket.driveCount)))
            }
        }

        guard driveCount > 0 else { return .empty }

        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let weekdayAverages: [WeekdayAverage] = (0..<7).compactMap { idx in
            guard counts[idx] > 0 else { return nil }
            return WeekdayAverage(
                weekdayIndex: idx,
                label: dayNames[idx],
                averageMinutes: sums[idx] / Double(counts[idx]) / 60,
                driveCount: counts[idx]
            )
        }

        return AggregateStats(
            driveCount: driveCount,
            totalDrivingSeconds: totalDriving,
            totalTrafficSeconds: totalTraffic,
            averageDurationSeconds: totalDriving / Double(driveCount),
            medianDurationSeconds: weightedPercentile(medianPairs, 0.5),
            p90DurationSeconds: weightedPercentile(p90Pairs, 0.9),
            weekdayAverages: weekdayAverages
        )
    }

    /// Step-function weighted percentile: smallest value whose cumulative
    /// weight reaches `p` of the total.
    nonisolated static func weightedPercentile(_ pairs: [(value: Double, weight: Double)], _ p: Double) -> Double {
        let valid = pairs.filter { $0.weight > 0 }.sorted { $0.value < $1.value }
        guard !valid.isEmpty else { return 0 }
        let total = valid.reduce(0) { $0 + $1.weight }
        let target = p * total
        var cumulative = 0.0
        for pair in valid {
            cumulative += pair.weight
            if cumulative >= target { return pair.value }
        }
        return valid[valid.count - 1].value
    }

    // MARK: - Fetching

    /// Completed-drive samples in [from, to), outliers removed, oldest
    /// first. Fetches only the scalar summary columns — the GPS blob is
    /// never materialized. `newestFirstLimit` bounds the fetch to the most
    /// recent N drives (result still returned oldest first).
    nonisolated static func fetchSamples(
        context: ModelContext,
        from start: Date?,
        to end: Date? = nil,
        newestFirstLimit: Int? = nil
    ) -> [DriveSample] {
        let lower = start ?? Date.distantPast
        let upper = end ?? Date.distantFuture
        let maxDuration = maxPlausibleDurationSeconds
        var descriptor = FetchDescriptor<DriveRecord>(
            predicate: #Predicate {
                $0.startedAt >= lower && $0.startedAt < upper &&
                ($0.totalDurationSeconds ?? 0) > 0 &&
                ($0.totalDurationSeconds ?? 0) <= maxDuration
            },
            sortBy: [SortDescriptor(\.startedAt, order: newestFirstLimit == nil ? .forward : .reverse)]
        )
        if let newestFirstLimit {
            descriptor.fetchLimit = newestFirstLimit
        }
        descriptor.propertiesToFetch = [\.startedAt, \.totalDurationSeconds, \.trafficDurationSeconds]

        let records = (try? context.fetch(descriptor)) ?? []
        let samples = records.map { record in
            DriveSample(
                startedAt: record.startedAt,
                durationSeconds: record.totalDurationSeconds ?? 0,
                trafficSeconds: record.trafficDurationSeconds ?? 0
            )
        }
        return newestFirstLimit == nil ? samples : samples.sorted { $0.startedAt < $1.startedAt }
    }

    /// Most recent drives for the list section, newest first, capped.
    ///
    /// Like `fetchSamples`, this projects only the scalar summary columns the row
    /// card renders (`id`, `startedAt`, `totalDurationSeconds`,
    /// `trafficDurationSeconds`) via `propertiesToFetch`, so the large inline GPS
    /// blob is not faulted in for the (up to 50) list rows. The blob and the
    /// `associatedCommute` relationship fault lazily on access — the row card
    /// reads only the projected scalars plus the commute name, and the GPS trace
    /// is decoded only in the detail path (`buildDriveDetail`).
    private func fetchRecentDrives(from windowStart: Date?, context: ModelContext) -> [DriveRecord] {
        var descriptor: FetchDescriptor<DriveRecord>
        if let windowStart {
            descriptor = FetchDescriptor<DriveRecord>(
                predicate: #Predicate { $0.startedAt >= windowStart },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<DriveRecord>(
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = Self.recentDriveLimit
        descriptor.propertiesToFetch = [\.id, \.startedAt, \.totalDurationSeconds, \.trafficDurationSeconds]
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Max legacy records finalized per backfill pass. A full batch signals more
    /// remain, so the caller queues another pass until the backlog drains.
    nonisolated static let backfillBatchSize = 200

    /// One-time migration for records saved before summary fields existed:
    /// decode their blobs once, persist the summaries, never decode again.
    ///
    /// Runs on a fresh background `ModelContext` (NOT the MainActor view context)
    /// because finalizing a record materializes and iterates its entire raw GPS
    /// blob — potentially thousands of points each — which would hitch the UI on
    /// the hottest analytics path. Returns how many records were finalized so the
    /// caller knows whether to re-aggregate and whether more remain.
    nonisolated static func backfillMissingSummaries(container: ModelContainer) -> Int {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<DriveRecord>(
            predicate: #Predicate { $0.endedAt != nil && $0.totalDurationSeconds == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = backfillBatchSize
        guard let legacy = try? context.fetch(descriptor), !legacy.isEmpty else { return 0 }
        for record in legacy {
            record.finalizeSummary()
        }
        try? context.save()
        return legacy.count
    }
}
