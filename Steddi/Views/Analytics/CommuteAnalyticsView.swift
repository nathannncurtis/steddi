import SwiftUI
import SwiftData
import Charts

/// Analytics container: time-window picker up top, then trends, aggregate
/// stats, time-in-traffic, and the recent-drive list.
///
/// All data flows through AnalyticsService, which reads cached summary
/// fields and aggregates — no GPS blobs are decoded rendering this screen.
struct CommuteAnalyticsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var service = AnalyticsService()
    @State private var window: AnalyticsTimeWindow = .fourWeeks

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    windowPicker

                    if service.aggregateStats.driveCount == 0 {
                        AnalyticsEmptyStateView()
                    } else {
                        trendsSection
                        statsSection
                        weekdaySection
                        trafficSection
                        drivesSection
                    }
                }
                .padding()
                .animation(.easeInOut(duration: 0.2), value: window)
            }
            .background(SteddiTheme.surfacePrimary)
            .navigationTitle("Analytics")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: DriveRecord.self) { record in
                DriveDetailView(record: record)
            }
            .onAppear {
                service.loadAnalytics(window: window, context: modelContext)
            }
            .onChange(of: window) { _, newWindow in
                service.loadAnalytics(window: newWindow, context: modelContext)
            }
        }
    }

    // MARK: - Time Window Picker

    private var windowPicker: some View {
        HStack(spacing: 4) {
            ForEach(AnalyticsTimeWindow.allCases) { option in
                Button {
                    window = option
                } label: {
                    Text(option.displayName)
                        .font(SteddiTheme.mono(13))
                        .foregroundStyle(window == option ? SteddiTheme.surfacePrimary : SteddiTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if window == option {
                                Capsule().fill(SteddiTheme.accent)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(SteddiTheme.surfaceSecondary))
    }

    // MARK: - Trends

    @ViewBuilder
    private var trendsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Trends")
            if let gate = service.trendGateMessage {
                trendGateCard(gate)
            } else {
                ForEach(service.trendInsights) { insight in
                    TrendInsightCard(insight: insight)
                }
            }
        }
    }

    private func trendGateCard(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 20))
                .foregroundStyle(SteddiTheme.accent)
            Text(message)
                .font(SteddiTheme.body(14))
                .foregroundStyle(SteddiTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                .fill(SteddiTheme.surfaceSecondary)
        }
    }

    // MARK: - Aggregate Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("At a Glance")
            AggregateStatsCards(stats: service.aggregateStats)
        }
    }

    // MARK: - Weekday Chart

    @ViewBuilder
    private var weekdaySection: some View {
        let weekdays = service.aggregateStats.weekdayAverages
        if !weekdays.isEmpty {
            chartSection(title: "Average by Day") {
                Chart(weekdays) { item in
                    BarMark(
                        x: .value("Day", item.label),
                        y: .value("Minutes", item.averageMinutes)
                    )
                    .foregroundStyle(SteddiTheme.accent.gradient)
                    .cornerRadius(6)
                }
                .chartXScale(domain: weekdays.map(\.label))
                .chartYAxisLabel("min")
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel().foregroundStyle(SteddiTheme.textSecondary)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(SteddiTheme.textMuted.opacity(0.15))
                        AxisValueLabel().foregroundStyle(SteddiTheme.textSecondary)
                    }
                }
                .frame(height: 200)
            }
        }
    }

    // MARK: - Time in Traffic

    @ViewBuilder
    private var trafficSection: some View {
        let data = service.trafficTimeData
        if data.count >= 2, data.contains(where: { $0.trafficMinutes > 0 }) {
            chartSection(title: "Time in Traffic") {
                Chart(data) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Minutes", point.trafficMinutes)
                    )
                    .foregroundStyle(SteddiTheme.warmRed.opacity(0.75))
                    .cornerRadius(3)
                }
                .chartYAxisLabel("min")
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel().foregroundStyle(SteddiTheme.textSecondary)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(SteddiTheme.textMuted.opacity(0.15))
                        AxisValueLabel().foregroundStyle(SteddiTheme.textSecondary)
                    }
                }
                .frame(height: 160)
            }
        }
    }

    // MARK: - Drives

    @ViewBuilder
    private var drivesSection: some View {
        if !service.recentDrives.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Drives")
                ForEach(service.recentDrives, id: \.id) { record in
                    NavigationLink(value: record) {
                        DriveRowCard(record: record)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(SteddiTheme.heading(18))
            .foregroundStyle(SteddiTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chartSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title)
            content()
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                        .fill(SteddiTheme.surfaceSecondary)
                }
        }
    }
}
