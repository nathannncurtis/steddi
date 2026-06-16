import Testing
import Foundation
import SwiftData
@testable import Steddi

// MARK: - AnalyticsService Tests

@Suite("AnalyticsService trends math")
struct AnalyticsServiceTrendsTests {

    /// Fixed gregorian/UTC calendar so weekday math is deterministic.
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Monday 2026-01-05 08:00 UTC.
    static let base: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = 5; components.hour = 8
        return utcCalendar.date(from: components)!
    }()

    static func sample(daysAfterBase: Int, minutes: Double, trafficMinutes: Double = 0) -> DriveSample {
        DriveSample(
            startedAt: base.addingTimeInterval(Double(daysAfterBase) * 86400),
            durationSeconds: minutes * 60,
            trafficSeconds: trafficMinutes * 60
        )
    }

    // MARK: Min-data guards

    @Test("No trends from zero drives")
    func gateEmpty() {
        let result = AnalyticsService.computeTrends(samples: [], now: Self.base, calendar: Self.utcCalendar)
        #expect(result.insights.isEmpty)
        #expect(result.gateMessage != nil)
    }

    @Test("No trend from 2 drives, even weeks apart")
    func gateTwoDrives() {
        let samples = [Self.sample(daysAfterBase: 0, minutes: 30), Self.sample(daysAfterBase: 21, minutes: 50)]
        let result = AnalyticsService.computeTrends(samples: samples, now: Self.base, calendar: Self.utcCalendar)
        #expect(result.insights.isEmpty)
        #expect(result.gateMessage != nil)
    }

    @Test("No trends when span is under two weeks")
    func gateShortSpan() {
        let samples = (0..<8).map { Self.sample(daysAfterBase: $0, minutes: 30 + Double($0)) }
        let result = AnalyticsService.computeTrends(samples: samples, now: Self.base, calendar: Self.utcCalendar)
        #expect(result.insights.isEmpty)
        #expect(result.gateMessage != nil)
    }

    @Test("Outlier drives over 5 hours don't count toward the minimum")
    func gateOutliersExcluded() {
        var samples = (0..<5).map { Self.sample(daysAfterBase: $0 * 5, minutes: 30) }
        samples.append(Self.sample(daysAfterBase: 26, minutes: 6 * 60)) // 6h glitch
        let result = AnalyticsService.computeTrends(samples: samples, now: Self.base, calendar: Self.utcCalendar)
        #expect(result.insights.isEmpty)
        #expect(result.gateMessage != nil)
    }

    // MARK: Overall trend

    @Test("Stable durations produce a steady insight, not a fake trend")
    func steadyInsight() {
        let samples = (0..<10).map { Self.sample(daysAfterBase: $0 * 3, minutes: 30) }
        let result = AnalyticsService.computeTrends(samples: samples, now: Self.base, calendar: Self.utcCalendar)
        #expect(result.gateMessage == nil)
        #expect(result.insights.contains { $0.id == "overall-steady" && $0.sentiment == .steady })
        #expect(!result.insights.contains { $0.id == "overall-slope" })
    }

    @Test("Worsening durations produce a worse-sentiment slope insight")
    func worseningSlope() {
        // +1 min per day = +7 min/week, well above the 1.5 min/week threshold
        let samples = (0..<10).map { Self.sample(daysAfterBase: $0 * 3, minutes: 30 + Double($0 * 3)) }
        let result = AnalyticsService.computeTrends(samples: samples, now: Self.base, calendar: Self.utcCalendar)
        let slope = result.insights.first { $0.id == "overall-slope" }
        #expect(slope != nil)
        #expect(slope?.sentiment == .worse)
        #expect((slope?.magnitudeMinutes ?? 0) > 1.5)
    }

    @Test("Improving durations produce a better-sentiment slope insight")
    func improvingSlope() {
        let samples = (0..<10).map { Self.sample(daysAfterBase: $0 * 3, minutes: 60 - Double($0 * 3)) }
        let result = AnalyticsService.computeTrends(samples: samples, now: Self.base, calendar: Self.utcCalendar)
        let slope = result.insights.first { $0.id == "overall-slope" }
        #expect(slope?.sentiment == .better)
    }

    // MARK: Weekday-over-weekday

    @Test("Tuesday getting 8 minutes worse is reported as a Tuesday insight")
    func tuesdayWorse() {
        // Base is a Monday, so day offset 1 is Tuesday. Six Tuesdays across
        // six weeks: first half 30 min, second half 38 min.
        var samples: [DriveSample] = []
        for week in 0..<6 {
            let minutes: Double = week < 3 ? 30 : 38
            samples.append(Self.sample(daysAfterBase: 1 + week * 7, minutes: minutes))
        }
        let result = AnalyticsService.computeTrends(samples: samples, now: Self.base, calendar: Self.utcCalendar)
        let tuesday = result.insights.first { $0.id == "weekday-2" }
        #expect(tuesday != nil)
        #expect(tuesday?.sentiment == .worse)
        #expect(abs((tuesday?.magnitudeMinutes ?? 0) - 8) < 0.5)
        #expect(tuesday?.message.contains("Tuesday") == true)
        #expect(tuesday?.message.contains("slower") == true)
    }

    @Test("Weekday insight requires at least 3 drives in each half")
    func weekdayMinSamples() {
        // Only 4 Tuesdays (halves of 2): not enough for a weekday insight,
        // pad with steady Wednesday drives to pass the overall gate.
        var samples: [DriveSample] = []
        for week in 0..<4 {
            samples.append(Self.sample(daysAfterBase: 1 + week * 7, minutes: week < 2 ? 30 : 50))
        }
        for week in 0..<4 {
            samples.append(Self.sample(daysAfterBase: 2 + week * 7, minutes: 30))
        }
        let result = AnalyticsService.computeTrends(samples: samples, now: Self.base, calendar: Self.utcCalendar)
        #expect(!result.insights.contains { $0.id.hasPrefix("weekday-") })
    }

    @Test("Sub-threshold weekday deltas are treated as noise")
    func weekdayNoiseFiltered() {
        var samples: [DriveSample] = []
        for week in 0..<6 {
            let minutes: Double = week < 3 ? 30 : 31 // 1 min delta < 3 min threshold
            samples.append(Self.sample(daysAfterBase: 1 + week * 7, minutes: minutes))
        }
        let result = AnalyticsService.computeTrends(samples: samples, now: Self.base, calendar: Self.utcCalendar)
        #expect(!result.insights.contains { $0.id.hasPrefix("weekday-") })
    }

    // MARK: Regression + percentile primitives

    @Test("Linear regression recovers a known slope")
    func regressionKnownSlope() {
        let xs: [Double] = [0, 1, 2, 3, 4]
        let ys = xs.map { 3 + 2 * $0 }
        let slope = AnalyticsService.linearRegressionSlope(xs: xs, ys: ys)
        #expect(slope != nil)
        #expect(abs((slope ?? 0) - 2) < 1e-9)
    }

    @Test("Regression is nil for degenerate input")
    func regressionDegenerate() {
        #expect(AnalyticsService.linearRegressionSlope(xs: [1], ys: [2]) == nil)
        #expect(AnalyticsService.linearRegressionSlope(xs: [2, 2, 2], ys: [1, 5, 9]) == nil)
        #expect(AnalyticsService.linearRegressionSlope(xs: [], ys: []) == nil)
    }

    @Test("Percentile interpolates between sorted values")
    func percentileMath() {
        let sorted: [Double] = [10, 20, 30, 40]
        #expect(AnalyticsService.percentile(sorted: sorted, 0.5) == 25)
        #expect(AnalyticsService.percentile(sorted: sorted, 0.0) == 10)
        #expect(AnalyticsService.percentile(sorted: sorted, 1.0) == 40)
        #expect(AnalyticsService.percentile(sorted: [], 0.5) == 0)
        #expect(AnalyticsService.percentile(sorted: [7], 0.9) == 7)
    }

    // MARK: Aggregate stats

    @Test("Aggregate stats bucket weekdays correctly")
    func aggregateWeekdayBuckets() {
        // Monday (base) at 40 min twice, Tuesday at 20 min once.
        let samples = [
            Self.sample(daysAfterBase: 0, minutes: 40),
            Self.sample(daysAfterBase: 7, minutes: 40),
            Self.sample(daysAfterBase: 1, minutes: 20, trafficMinutes: 5)
        ]
        let stats = AnalyticsService.computeAggregateStats(samples: samples, calendar: Self.utcCalendar)
        #expect(stats.driveCount == 3)
        #expect(abs(stats.totalDrivingSeconds - 100 * 60) < 0.001)
        #expect(abs(stats.totalTrafficSeconds - 5 * 60) < 0.001)
        let monday = stats.weekdayAverages.first { $0.weekdayIndex == 1 }
        let tuesday = stats.weekdayAverages.first { $0.weekdayIndex == 2 }
        #expect(monday?.averageMinutes == 40)
        #expect(monday?.driveCount == 2)
        #expect(tuesday?.averageMinutes == 20)
        #expect(stats.weekdayAverages.count == 2)
    }

    @Test("Empty samples produce the empty aggregate")
    func aggregateEmpty() {
        #expect(AnalyticsService.computeAggregateStats(samples: [], calendar: Self.utcCalendar) == .empty)
    }
}

// MARK: - Chart Builder Tests

@Suite("AnalyticsService chart builders")
struct AnalyticsChartBuilderTests {

    static func point(offset: TimeInterval, speed: Double) -> GPSPoint {
        GPSPoint(
            latitude: 33.0 + offset * 1e-6,
            longitude: -117.0,
            altitude: 0,
            horizontalAccuracy: 5,
            timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000 + offset),
            speed: speed
        )
    }

    @Test("Speed chart caps point count at maxPoints")
    func speedChartResamples() {
        let points = (0..<1000).map { Self.point(offset: Double($0), speed: 10) }
        let chart = AnalyticsService.buildSpeedChart(points: points, maxPoints: 160)
        #expect(chart.count <= 160)
        #expect(chart.count > 100)
        #expect(chart.allSatisfy { abs($0.speedMps - 10) < 0.001 })
    }

    @Test("Speed chart passes small traces through untouched")
    func speedChartSmallTrace() {
        let points = (0..<50).map { Self.point(offset: Double($0 * 3), speed: Double($0)) }
        let chart = AnalyticsService.buildSpeedChart(points: points, maxPoints: 160)
        #expect(chart.count == 50)
        #expect(chart.first?.offsetSeconds == 0)
        #expect(chart.last?.speedMps == 49)
    }

    @Test("Speed chart drops invalid and implausible speeds")
    func speedChartFilters() {
        var points = [Self.point(offset: 0, speed: -1), Self.point(offset: 1, speed: 100)]
        points.append(contentsOf: (2..<10).map { Self.point(offset: Double($0), speed: 5) })
        let chart = AnalyticsService.buildSpeedChart(points: points)
        #expect(chart.allSatisfy { $0.speedMps == 5 })
    }

    @Test("Speed chart is empty for traces with fewer than 2 valid points")
    func speedChartEmpty() {
        #expect(AnalyticsService.buildSpeedChart(points: []).isEmpty)
        #expect(AnalyticsService.buildSpeedChart(points: [Self.point(offset: 0, speed: 5)]).isEmpty)
    }

    @Test("Traffic ranges find contiguous slow stretches")
    func trafficRangeDetection() {
        let speeds: [Double] = [10, 1, 1, 1, 10, 10, 0.5, 0.5]
        let points = speeds.enumerated().map { idx, speed in
            SpeedTrendPoint(offsetSeconds: Double(idx * 10), speedMps: speed)
        }
        let ranges = AnalyticsService.trafficRanges(in: points)
        #expect(ranges.count == 2)
        #expect(ranges[0] == 10.0...30.0)
        #expect(ranges[1] == 60.0...70.0)
    }

    @Test("Traffic chart orders drives oldest first")
    func trafficChartOrdering() {
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let samples = [
            DriveSample(startedAt: now.addingTimeInterval(86400), durationSeconds: 1800, trafficSeconds: 300),
            DriveSample(startedAt: now, durationSeconds: 1800, trafficSeconds: 600)
        ]
        let chart = AnalyticsService.buildTrafficChart(samples: samples)
        #expect(chart.count == 2)
        #expect(chart[0].date == now)
        #expect(chart[0].trafficMinutes == 10)
        #expect(chart[1].trafficMinutes == 5)
    }

    @Test("Out-of-order timestamp before chart start does not crash and buckets sanely")
    func speedChartHandlesOutOfOrderTimestamps() {
        // Enough samples to force the bucketing branch (count > maxPoints).
        var points = (0..<400).map { Self.point(offset: Double($0), speed: 10) }
        // Inject a sample whose timestamp is earlier than valid.first's (clock
        // adjustment / out-of-order GPS) — its offset is negative, which without
        // a lower clamp computes a negative bucket index and crashes on subscript.
        points.append(Self.point(offset: -50, speed: 3))
        // And one past the chronological end for the upper bound too.
        points.append(Self.point(offset: 100_000, speed: 7))

        let chart = AnalyticsService.buildSpeedChart(points: points, maxPoints: 160)

        // No crash; produces a bounded, sane chart with every value plausible.
        #expect(!chart.isEmpty)
        #expect(chart.count <= 160)
        #expect(chart.allSatisfy { $0.offsetSeconds >= 0 })
        #expect(chart.allSatisfy { $0.speedMps >= 0 && $0.speedMps <= DriveRecord.maxPlausibleSpeedMps })
    }

    @Test("Route samples cap count and drop low-accuracy fixes")
    func routeSampleResampling() {
        var points = (0..<900).map { Self.point(offset: Double($0), speed: 8) }
        points.append(GPSPoint(
            latitude: 34, longitude: -118, altitude: 0,
            horizontalAccuracy: 200,
            timestamp: Date(timeIntervalSinceReferenceDate: 700_001_000), speed: 8
        ))
        let samples = AnalyticsService.buildRouteSamples(points: points, maxPoints: 300)
        #expect(samples.count == 300)
        #expect(samples.allSatisfy { $0.coordinate.latitude < 33.1 })
    }
}

// MARK: - DriveRecord Summary Tests

@Suite("DriveRecord computed-on-write summary")
struct DriveRecordSummaryTests {

    static func point(start: Date, offset: TimeInterval, speed: Double) -> GPSPoint {
        GPSPoint(
            latitude: 33, longitude: -117, altitude: 0, horizontalAccuracy: 5,
            timestamp: start.addingTimeInterval(offset), speed: speed
        )
    }

    @Test("finalizeSummary computes duration, traffic, and speed stats")
    func summaryBasics() {
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let record = DriveRecord(startedAt: start)
        // 0-30s at 1 m/s (traffic), 30-60s at 20 m/s
        record.rawGPSPoints = (0...20).map { i in
            Self.point(start: start, offset: Double(i * 3), speed: i < 10 ? 1.0 : 20.0)
        }
        record.endedAt = start.addingTimeInterval(60)
        record.finalizeSummary()

        #expect(record.totalDurationSeconds == 60)
        #expect(record.maxSpeedMps == 20)
        // 10 slow samples each crediting a 3s gap
        #expect(abs((record.trafficDurationSeconds ?? 0) - 30) < 0.001)
        let expectedAvg = (10.0 * 1.0 + 11.0 * 20.0) / 21.0
        #expect(abs((record.averageSpeedMps ?? 0) - expectedAvg) < 0.001)
        #expect(record.hasSummary)
    }

    @Test("Duration comes from the GPS trace span, not back-to-back Date() calls")
    func summaryDurationFromTrace() {
        // Reproduces the production write path: `DriveRecord()` defaults
        // startedAt to NOW (the END of the drive), then endedAt is set to NOW a
        // moment later — so endedAt - startedAt ≈ 0. The real 25-minute span
        // lives only in the GPS timestamps. finalizeSummary must recover it.
        let end = Date()
        let record = DriveRecord() // startedAt defaults to ~end (the bug)
        record.endedAt = end
        let traceStart = end.addingTimeInterval(-25 * 60) // 25 min before "end"
        record.rawGPSPoints = (0...50).map { i in
            Self.point(start: traceStart, offset: Double(i) * 30, speed: 15)
        }
        record.finalizeSummary()
        // 50 intervals * 30s = 1500s = 25 min, NOT ~0.
        #expect(abs((record.totalDurationSeconds ?? 0) - 1500) < 1.0)

        // And the analytics that consume it reflect the real duration: a single
        // 25-minute drive yields a 25-minute average, not 0.
        let sample = DriveSample(
            startedAt: record.startedAt,
            durationSeconds: record.totalDurationSeconds ?? 0,
            trafficSeconds: record.trafficDurationSeconds ?? 0
        )
        let stats = AnalyticsService.computeAggregateStats(samples: [sample])
        #expect(stats.driveCount == 1)
        #expect(abs(stats.averageDurationMinutes - 25) < 0.1)
        #expect(abs(stats.totalDrivingSeconds - 1500) < 1.0)
    }

    @Test("GPS dropouts don't count as traffic time")
    func summaryGapCap() {
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let record = DriveRecord(startedAt: start)
        record.rawGPSPoints = [
            Self.point(start: start, offset: 0, speed: 0.5),
            Self.point(start: start, offset: 120, speed: 0.5), // 2 min signal gap
            Self.point(start: start, offset: 123, speed: 0.5)
        ]
        record.endedAt = start.addingTimeInterval(130)
        record.finalizeSummary()
        // Only the 3s gap counts; the 120s dropout is excluded.
        #expect(abs((record.trafficDurationSeconds ?? 0) - 3) < 0.001)
    }

    @Test("Implausible speeds are excluded from stats")
    func summaryOutlierSpeeds() {
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let record = DriveRecord(startedAt: start)
        record.rawGPSPoints = [
            Self.point(start: start, offset: 0, speed: 10),
            Self.point(start: start, offset: 3, speed: 95), // 212 mph glitch
            Self.point(start: start, offset: 6, speed: -1)  // unavailable
        ]
        record.endedAt = start.addingTimeInterval(10)
        record.finalizeSummary()
        #expect(record.maxSpeedMps == 10)
        #expect(record.averageSpeedMps == 10)
    }

    @Test("finalizeSummary without endedAt leaves the record unsummarized")
    func summaryRequiresEnd() {
        let record = DriveRecord()
        record.finalizeSummary()
        #expect(!record.hasSummary)
    }

    @Test("finalizeSummary is idempotent")
    func summaryIdempotent() {
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let record = DriveRecord(startedAt: start)
        record.rawGPSPoints = (0..<10).map { Self.point(start: start, offset: Double($0 * 3), speed: 15) }
        record.endedAt = start.addingTimeInterval(30)
        record.finalizeSummary()
        let firstPass = (record.totalDurationSeconds, record.trafficDurationSeconds, record.maxSpeedMps, record.averageSpeedMps)
        record.finalizeSummary()
        #expect(record.totalDurationSeconds == firstPass.0)
        #expect(record.trafficDurationSeconds == firstPass.1)
        #expect(record.maxSpeedMps == firstPass.2)
        #expect(record.averageSpeedMps == firstPass.3)
    }
}

// MARK: - Aggregation Cache Invalidation Tests

@Suite("Analytics aggregation invalidation", .serialized)
struct AnalyticsAggregationTests {

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Wednesday 2026-03-18 12:00 UTC — mid-week so the current week is open.
    static let now: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 18; components.hour = 12
        return utcCalendar.date(from: components)!
    }()

    static func makeStore() throws -> (container: ModelContainer, context: ModelContext) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: config)
        return (container, ModelContext(container))
    }

    @discardableResult
    static func insertDrive(
        _ context: ModelContext, startedAt: Date, minutes: Double, trafficMinutes: Double = 0
    ) -> DriveRecord {
        let record = DriveRecord(startedAt: startedAt)
        record.endedAt = startedAt.addingTimeInterval(minutes * 60)
        record.totalDurationSeconds = minutes * 60
        record.trafficDurationSeconds = trafficMinutes * 60
        context.insert(record)
        return record
    }

    static func allBuckets(_ context: ModelContext) -> [CommuteAnalyticsAggregate] {
        let descriptor = FetchDescriptor<CommuteAnalyticsAggregate>(sortBy: [SortDescriptor(\.weekStart)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @Test("Rebuild creates buckets for closed weeks only")
    func rebuildBucketsClosedWeeks() throws {
        let (container, context) = try Self.makeStore()
        _ = container
        let week = AnalyticsService.weekStart(for: Self.now, calendar: Self.utcCalendar)

        // 2 drives two weeks ago, 3 one week ago, 1 in the open week.
        Self.insertDrive(context, startedAt: week.addingTimeInterval(-14 * 86400), minutes: 30)
        Self.insertDrive(context, startedAt: week.addingTimeInterval(-13 * 86400), minutes: 34)
        Self.insertDrive(context, startedAt: week.addingTimeInterval(-7 * 86400), minutes: 28, trafficMinutes: 6)
        Self.insertDrive(context, startedAt: week.addingTimeInterval(-6 * 86400), minutes: 30)
        Self.insertDrive(context, startedAt: week.addingTimeInterval(-5 * 86400), minutes: 32)
        Self.insertDrive(context, startedAt: week.addingTimeInterval(1 * 86400), minutes: 40)
        try context.save()

        AnalyticsService.rebuildAggregates(context: context, now: Self.now, calendar: Self.utcCalendar)

        let buckets = Self.allBuckets(context)
        #expect(buckets.count == 2)
        #expect(buckets[0].driveCount == 2)
        #expect(abs(buckets[0].totalDrivingSeconds - 64 * 60) < 0.001)
        #expect(buckets[1].driveCount == 3)
        #expect(abs(buckets[1].totalTrafficSeconds - 6 * 60) < 0.001)
        #expect(buckets.allSatisfy { $0.weekStart < week })
    }

    @Test("Fresh cache reports no rebuild needed; new drives invalidate it")
    func invalidationOnNewDrive() throws {
        let (container, context) = try Self.makeStore()
        _ = container
        let week = AnalyticsService.weekStart(for: Self.now, calendar: Self.utcCalendar)
        for day in [-14, -12, -7] {
            Self.insertDrive(context, startedAt: week.addingTimeInterval(Double(day) * 86400), minutes: 30)
        }
        try context.save()
        AnalyticsService.rebuildAggregates(context: context, now: Self.now, calendar: Self.utcCalendar)

        #expect(!AnalyticsService.aggregatesNeedRebuild(context: context, now: Self.now, calendar: Self.utcCalendar))

        // A drive landing in an already-cached week invalidates the cache.
        Self.insertDrive(context, startedAt: week.addingTimeInterval(-13 * 86400), minutes: 45)
        try context.save()
        #expect(AnalyticsService.aggregatesNeedRebuild(context: context, now: Self.now, calendar: Self.utcCalendar))

        AnalyticsService.rebuildAggregates(context: context, now: Self.now, calendar: Self.utcCalendar)
        let buckets = Self.allBuckets(context)
        #expect(buckets.first?.driveCount == 3)
        #expect(!AnalyticsService.aggregatesNeedRebuild(context: context, now: Self.now, calendar: Self.utcCalendar))
    }

    @Test("Stale buckets are regenerated even when counts match")
    func staleBucketRegenerated() throws {
        let (container, context) = try Self.makeStore()
        _ = container
        let week = AnalyticsService.weekStart(for: Self.now, calendar: Self.utcCalendar)
        for day in [-14, -13, -12] {
            Self.insertDrive(context, startedAt: week.addingTimeInterval(Double(day) * 86400), minutes: 30)
        }
        try context.save()
        AnalyticsService.rebuildAggregates(context: context, now: Self.now, calendar: Self.utcCalendar)

        // Age the bucket past the staleness horizon and corrupt a value
        // the count check can't see.
        let bucket = try #require(Self.allBuckets(context).first)
        bucket.generatedAt = Self.now.addingTimeInterval(-8 * 86400)
        bucket.averageDurationSeconds = 999_999
        try context.save()

        #expect(AnalyticsService.aggregatesNeedRebuild(context: context, now: Self.now, calendar: Self.utcCalendar))
        AnalyticsService.rebuildAggregates(context: context, now: Self.now, calendar: Self.utcCalendar)

        let refreshed = try #require(Self.allBuckets(context).first)
        #expect(abs(refreshed.averageDurationSeconds - 30 * 60) < 0.001)
        #expect(refreshed.generatedAt == Self.now)
    }

    @Test("Buckets for weeks with no remaining drives are deleted")
    func orphanBucketDeleted() throws {
        let (container, context) = try Self.makeStore()
        _ = container
        let week = AnalyticsService.weekStart(for: Self.now, calendar: Self.utcCalendar)
        let doomed = Self.insertDrive(context, startedAt: week.addingTimeInterval(-14 * 86400), minutes: 30)
        Self.insertDrive(context, startedAt: week.addingTimeInterval(-7 * 86400), minutes: 30)
        try context.save()
        AnalyticsService.rebuildAggregates(context: context, now: Self.now, calendar: Self.utcCalendar)
        #expect(Self.allBuckets(context).count == 2)

        context.delete(doomed)
        try context.save()
        #expect(AnalyticsService.aggregatesNeedRebuild(context: context, now: Self.now, calendar: Self.utcCalendar))

        AnalyticsService.rebuildAggregates(context: context, now: Self.now, calendar: Self.utcCalendar)
        let buckets = Self.allBuckets(context)
        #expect(buckets.count == 1)
        #expect(buckets[0].weekStart == week.addingTimeInterval(-7 * 86400))
    }

    @Test("Cache-first stats merge buckets with the open week exactly")
    func cacheFirstMerge() throws {
        let (container, context) = try Self.makeStore()
        _ = container
        let week = AnalyticsService.weekStart(for: Self.now, calendar: Self.utcCalendar)
        Self.insertDrive(context, startedAt: week.addingTimeInterval(-14 * 86400), minutes: 30, trafficMinutes: 5)
        Self.insertDrive(context, startedAt: week.addingTimeInterval(-7 * 86400), minutes: 40, trafficMinutes: 10)
        Self.insertDrive(context, startedAt: week.addingTimeInterval(1 * 86400), minutes: 50, trafficMinutes: 15)
        try context.save()
        AnalyticsService.rebuildAggregates(context: context, now: Self.now, calendar: Self.utcCalendar)

        let stats = AnalyticsService.cacheFirstStats(
            context: context, windowStart: nil, now: Self.now, calendar: Self.utcCalendar
        )
        #expect(stats.driveCount == 3)
        #expect(abs(stats.totalDrivingSeconds - 120 * 60) < 0.001)
        #expect(abs(stats.totalTrafficSeconds - 30 * 60) < 0.001)
        #expect(abs(stats.averageDurationSeconds - 40 * 60) < 0.001)
    }

    @Test("Merged weekday averages are exact across buckets and loose samples")
    func mergeWeekdayExact() throws {
        let calendar = Self.utcCalendar
        let week = AnalyticsService.weekStart(for: Self.now, calendar: calendar)

        // Bucket holds one Monday drive of 30 min.
        let bucket = CommuteAnalyticsAggregate(weekStart: week.addingTimeInterval(-7 * 86400))
        bucket.driveCount = 1
        bucket.totalDrivingSeconds = 30 * 60
        bucket.medianDurationSeconds = 30 * 60
        bucket.p90DurationSeconds = 30 * 60
        bucket.averageDurationSeconds = 30 * 60
        var sums = Array(repeating: 0.0, count: 7)
        var counts = Array(repeating: 0, count: 7)
        sums[1] = 30 * 60; counts[1] = 1
        bucket.weekdayDurationSums = sums
        bucket.weekdayDriveCounts = counts

        // Loose sample: another Monday drive of 50 min (week start is Sunday
        // for the gregorian calendar, so +1 day is Monday).
        let loose = [DriveSample(
            startedAt: week.addingTimeInterval(1 * 86400),
            durationSeconds: 50 * 60,
            trafficSeconds: 0
        )]

        let stats = AnalyticsService.mergeAggregates([bucket], looseSamples: loose, calendar: calendar)
        let monday = stats.weekdayAverages.first { $0.weekdayIndex == 1 }
        #expect(monday?.driveCount == 2)
        #expect(abs((monday?.averageMinutes ?? 0) - 40) < 0.001)
    }

    @Test("Weighted percentile picks the value at the cumulative target")
    func weightedPercentileMath() {
        let pairs: [(value: Double, weight: Double)] = [(10, 1), (20, 1), (30, 1), (40, 1)]
        #expect(AnalyticsService.weightedPercentile(pairs, 0.5) == 20)
        #expect(AnalyticsService.weightedPercentile(pairs, 0.9) == 40)
        #expect(AnalyticsService.weightedPercentile([(25, 12)], 0.5) == 25)
        #expect(AnalyticsService.weightedPercentile([], 0.5) == 0)
        // Zero-weight entries are ignored.
        #expect(AnalyticsService.weightedPercentile([(5, 0), (15, 3)], 0.5) == 15)
    }
}

// MARK: - Legacy summary backfill

/// `backfillMissingSummaries` is the migration path for records saved before the
/// computed-on-write summary fields existed. It must run OFF the MainActor (it
/// decodes the full GPS blob), finalize only legacy records, and report how many
/// it touched so the caller can re-aggregate and keep draining.
@Suite("Analytics legacy backfill")
struct AnalyticsBackfillTests {

    static func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ModelStoreLocator.schema, configurations: config)
    }

    /// A legacy record: ended, but with the summary fields still nil and a real
    /// GPS trace that finalizeSummary must decode.
    @discardableResult
    static func insertLegacy(_ context: ModelContext, start: Date, minutes: Double) -> DriveRecord {
        let record = DriveRecord(startedAt: start)
        record.endedAt = start.addingTimeInterval(minutes * 60)
        // Two valid fixes 1s apart at ~10 m/s so the summary computes non-trivially.
        record.rawGPSPoints = [
            GPSPoint(latitude: 34.0, longitude: -118.0, altitude: 0, horizontalAccuracy: 5, timestamp: start, speed: 10),
            GPSPoint(latitude: 34.0001, longitude: -118.0, altitude: 0, horizontalAccuracy: 5, timestamp: start.addingTimeInterval(1), speed: 10)
        ]
        // totalDurationSeconds left nil — this is what marks it as un-backfilled.
        context.insert(record)
        return record
    }

    static func allRecords(_ context: ModelContext) -> [DriveRecord] {
        (try? context.fetch(FetchDescriptor<DriveRecord>())) ?? []
    }

    @Test("Backfill finalizes legacy records and reports the count")
    func backfillFinalizes() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        Self.insertLegacy(context, start: start, minutes: 20)
        Self.insertLegacy(context, start: start.addingTimeInterval(3600), minutes: 30)
        try context.save()

        let count = AnalyticsService.backfillMissingSummaries(container: container)
        #expect(count == 2)

        // Read back through a fresh context (mirrors the re-aggregate path).
        let verify = ModelContext(container)
        let records = Self.allRecords(verify)
        #expect(records.allSatisfy { $0.totalDurationSeconds != nil })
        #expect(records.allSatisfy { $0.hasSummary })
    }

    /// The view's long-lived (main) context materializes a legacy record with
    /// its summary still nil. A background context then finalizes that SAME
    /// record in the store. Without refreshing, the main context keeps handing
    /// back the stale registered object (nil duration) on re-fetch — the
    /// just-backfilled drive only appears after relaunch. `refreshFromStore`
    /// must make the freshly-persisted value visible to the view context
    /// WITHOUT recreating the container.
    @Test("Backfilled summaries become visible to the view context without relaunch")
    @MainActor
    func backfillVisibleToViewContext() throws {
        let container = try Self.makeContainer()
        let viewContext = ModelContext(container) // stands in for the view's main context

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        Self.insertLegacy(viewContext, start: start, minutes: 20)
        try viewContext.save()

        // Materialize the record in the view context, exactly as fetchRecentDrives
        // / fetchSamples would on first paint — registering it with nil duration.
        let before = Self.allRecords(viewContext)
        #expect(before.count == 1)
        #expect(before.first?.totalDurationSeconds == nil)

        // Background context finalizes the record in the store (mirrors
        // backfillMissingSummaries running off the MainActor on a fresh context).
        let backfilled = AnalyticsService.backfillMissingSummaries(container: container)
        #expect(backfilled == 1)

        // The fix: refresh the view context from the store, then re-fetch.
        AnalyticsService.refreshFromStore(viewContext)
        let fresh = Self.allRecords(viewContext)
        #expect(fresh.first?.totalDurationSeconds != nil)
        #expect((fresh.first?.totalDurationSeconds ?? 0) > 0)
        #expect(fresh.first?.hasSummary == true)
    }

    @Test("Backfill leaves already-summarized records untouched and returns 0")
    func backfillSkipsFinalized() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let record = DriveRecord(startedAt: start)
        record.endedAt = start.addingTimeInterval(1200)
        record.finalizeSummary() // already has a summary
        context.insert(record)
        try context.save()

        let count = AnalyticsService.backfillMissingSummaries(container: container)
        #expect(count == 0)
    }
}
