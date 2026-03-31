import SwiftUI
import SwiftData
import Charts

struct CommuteAnalyticsView: View {
    @Query(sort: \DriveRecord.startedAt, order: .reverse) private var records: [DriveRecord]
    @Query(sort: \CommuteTrip.timestamp, order: .reverse) private var trips: [CommuteTrip]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Summary stats
                    summaryCards

                    // Time by day of week
                    if !weekdayData.isEmpty {
                        chartSection(title: "Average by Day") {
                            Chart(weekdayData, id: \.day) { item in
                                BarMark(
                                    x: .value("Day", item.day),
                                    y: .value("Minutes", item.avgMinutes)
                                )
                                .foregroundStyle(Color(red: 0.608, green: 0.557, blue: 0.769))
                                .cornerRadius(6)
                            }
                            .frame(height: 200)
                            .chartYAxisLabel("min")
                        }
                    }

                    // Recent drives
                    if !recentDrives.isEmpty {
                        sectionHeader("Recent Drives")
                        ForEach(recentDrives, id: \.id) { record in
                            driveRow(record)
                        }
                    }
                }
                .padding()
            }
            .background(SteddiTheme.surfacePrimary)
            .navigationTitle("Analytics")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Summary

    var summaryCards: some View {
        let totalDrives = records.count
        let totalMinutes = records.compactMap { r -> Double? in
            guard let end = r.endedAt else { return nil }
            return end.timeIntervalSince(r.startedAt) / 60
        }.reduce(0, +)
        let avgMinutes = totalDrives > 0 ? totalMinutes / Double(totalDrives) : 0
        let trafficMinutes = records.flatMap { $0.rawGPSPoints }
            .filter { $0.speed >= 0 && $0.speed < 2.0 } // stopped/crawling
            .count // each point is ~3 seconds
        let trafficHours = Double(trafficMinutes * 3) / 3600.0

        return HStack(spacing: 12) {
            statCard(value: "\(totalDrives)", label: "Drives")
            statCard(value: String(format: "%.0f", avgMinutes), label: "Avg min")
            statCard(value: String(format: "%.1f", totalMinutes / 60), label: "Total hrs")
            statCard(value: String(format: "%.1f", trafficHours), label: "In traffic")
        }
    }

    func statCard(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundStyle(SteddiTheme.textPrimary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(SteddiTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(SteddiTheme.surfaceSecondary)
        .cornerRadius(14)
    }

    // MARK: - Weekday Chart Data

    struct WeekdayItem {
        let day: String
        let avgMinutes: Double
    }

    var weekdayData: [WeekdayItem] {
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var buckets: [[Double]] = Array(repeating: [], count: 7)

        for record in records {
            guard let end = record.endedAt else { continue }
            let minutes = end.timeIntervalSince(record.startedAt) / 60
            guard minutes > 0 && minutes < 300 else { continue } // filter outliers
            let weekday = Calendar.current.component(.weekday, from: record.startedAt) - 1
            buckets[weekday].append(minutes)
        }

        return buckets.enumerated().compactMap { idx, values in
            guard !values.isEmpty else { return nil }
            let avg = values.reduce(0, +) / Double(values.count)
            return WeekdayItem(day: dayNames[idx], avgMinutes: avg)
        }
    }

    // MARK: - Recent Drives

    var recentDrives: [DriveRecord] {
        Array(records.prefix(10))
    }

    func driveRow(_ record: DriveRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.associatedCommute?.name ?? "Drive")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Text(record.startedAt, style: .date)
                    .font(.system(size: 12))
                    .foregroundStyle(SteddiTheme.textSecondary)
            }
            Spacer()
            if let end = record.endedAt {
                let minutes = Int(end.timeIntervalSince(record.startedAt) / 60)
                Text("\(minutes) min")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SteddiTheme.textPrimary)
            }
        }
        .padding(16)
        .background(SteddiTheme.surfaceSecondary)
        .cornerRadius(14)
    }

    // MARK: - Helpers

    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(SteddiTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func chartSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title)
            content()
                .padding(16)
                .background(SteddiTheme.surfaceSecondary)
                .cornerRadius(14)
        }
    }
}
