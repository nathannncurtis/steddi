import Foundation
import SwiftData

/// Pre-aggregated analytics bucket — one row per calendar week.
///
/// Analytics views read these rows instead of iterating every DriveRecord
/// (and decoding GPS blobs) on appear. Buckets are rebuilt lazily by
/// AnalyticsService when stale or when the underlying drive count changes.
@Model
final class CommuteAnalyticsAggregate {
    #Index<CommuteAnalyticsAggregate>([\.weekStart])

    /// Start of the calendar week this bucket covers (Calendar.current,
    /// stored as a UTC instant).
    var weekStart: Date

    /// Number of completed, non-outlier drives in the week.
    var driveCount: Int

    /// Sum of total drive durations (seconds) across the week.
    var totalDrivingSeconds: Double

    /// Sum of time spent stopped or crawling in traffic (seconds).
    var totalTrafficSeconds: Double

    /// Mean drive duration in seconds.
    var averageDurationSeconds: Double

    /// 50th percentile drive duration in seconds.
    var medianDurationSeconds: Double

    /// 90th percentile drive duration in seconds.
    var p90DurationSeconds: Double

    /// Per-weekday duration sums in seconds. Index 0 = Sunday ... 6 = Saturday
    /// (Calendar weekday component minus one). Always 7 entries.
    var weekdayDurationSums: [Double]

    /// Per-weekday drive counts, same indexing as `weekdayDurationSums`.
    var weekdayDriveCounts: [Int]

    /// When this bucket was last rebuilt. Buckets older than
    /// `CommuteAnalyticsAggregate.staleAfter` are regenerated on next load.
    var generatedAt: Date

    init(
        weekStart: Date,
        driveCount: Int = 0,
        totalDrivingSeconds: Double = 0,
        totalTrafficSeconds: Double = 0,
        averageDurationSeconds: Double = 0,
        medianDurationSeconds: Double = 0,
        p90DurationSeconds: Double = 0,
        weekdayDurationSums: [Double] = Array(repeating: 0, count: 7),
        weekdayDriveCounts: [Int] = Array(repeating: 0, count: 7),
        generatedAt: Date = Date()
    ) {
        self.weekStart = weekStart
        self.driveCount = driveCount
        self.totalDrivingSeconds = totalDrivingSeconds
        self.totalTrafficSeconds = totalTrafficSeconds
        self.averageDurationSeconds = averageDurationSeconds
        self.medianDurationSeconds = medianDurationSeconds
        self.p90DurationSeconds = p90DurationSeconds
        self.weekdayDurationSums = weekdayDurationSums
        self.weekdayDriveCounts = weekdayDriveCounts
        self.generatedAt = generatedAt
    }

    /// Buckets older than this are rebuilt from raw records on next load.
    static let staleAfter: TimeInterval = 7 * 24 * 3600

    var isStale: Bool {
        isStale(asOf: Date())
    }

    func isStale(asOf date: Date) -> Bool {
        date.timeIntervalSince(generatedAt) > Self.staleAfter
    }
}
