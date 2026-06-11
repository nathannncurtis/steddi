import Testing
import Foundation
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
