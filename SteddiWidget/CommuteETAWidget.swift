import WidgetKit
import SwiftUI

/// App Group keys written by NavigationStateManager (kept in sync there).
private enum WidgetKeys {
    static let commuteName = "widget.commuteName"
    static let destinationName = "widget.destinationName"
    static let isNavigating = "widget.isNavigating"
    static let etaMinutes = "widget.etaMinutes"
    static let etaUpdatedAt = "widget.etaUpdatedAt"
}

/// How long an idle ETA is considered "fresh" enough to present as a current
/// glance rather than a clearly-stale last-known value (seconds).
private let etaFreshnessWindow: TimeInterval = 30 * 60

/// Data for the commute ETA widget
struct CommuteETAEntry: TimelineEntry {
    let date: Date
    let commuteName: String
    let etaMinutes: Int?
    let destinationName: String
    let isNavigating: Bool
    /// When the ETA was computed, if known. Drives the freshness label so a
    /// value written by an earlier drive/check isn't shown as if it were live.
    let etaUpdatedAt: Date?

    /// The ETA is considered stale (worth labeling as last-known) when it isn't
    /// live and was computed outside the freshness window.
    var isStale: Bool {
        guard !isNavigating, let updated = etaUpdatedAt else { return false }
        return date.timeIntervalSince(updated) > etaFreshnessWindow
    }
}

/// Timeline provider — reads shared data from App Group
struct CommuteETAProvider: TimelineProvider {
    private let defaults = UserDefaults(suiteName: "group.to.nathancurtis.steddi")

    func placeholder(in context: Context) -> CommuteETAEntry {
        CommuteETAEntry(date: .now, commuteName: "Work", etaMinutes: 35, destinationName: "Office", isNavigating: false, etaUpdatedAt: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (CommuteETAEntry) -> Void) {
        let entry = currentEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CommuteETAEntry>) -> Void) {
        let entry = currentEntry()
        // Refresh every 15 minutes so the freshness label/relative age advances
        // even when the app doesn't write new defaults in between.
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func currentEntry() -> CommuteETAEntry {
        let name = defaults?.string(forKey: WidgetKeys.commuteName) ?? "Commute"
        let eta = defaults?.integer(forKey: WidgetKeys.etaMinutes) ?? 0
        let dest = defaults?.string(forKey: WidgetKeys.destinationName) ?? ""
        let isNav = defaults?.bool(forKey: WidgetKeys.isNavigating) ?? false
        let updatedRaw = defaults?.double(forKey: WidgetKeys.etaUpdatedAt) ?? 0

        return CommuteETAEntry(
            date: .now,
            commuteName: name,
            etaMinutes: eta == 0 ? nil : eta,
            destinationName: dest,
            isNavigating: isNav,
            etaUpdatedAt: updatedRaw > 0 ? Date(timeIntervalSince1970: updatedRaw) : nil
        )
    }
}

/// The widget definition
struct CommuteETAWidget: Widget {
    let kind: String = "CommuteETAWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CommuteETAProvider()) { entry in
            CommuteETAView(entry: entry)
                .containerBackground(Color(red: 0.055, green: 0.051, blue: 0.071), for: .widget)
        }
        .configurationDisplayName("Next Commute")
        .description("See your commute ETA at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Widget view
struct CommuteETAView: View {
    let entry: CommuteETAEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "car.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.608, green: 0.557, blue: 0.769))
                Text(entry.commuteName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            if let eta = entry.etaMinutes {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(eta)")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("min")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                }
                if entry.isStale, let updated = entry.etaUpdatedAt {
                    Text("as of \(updated, style: .time)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
            } else {
                Text("No ETA yet")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if !entry.destinationName.isEmpty {
                Text("to \(entry.destinationName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .padding(4)
    }

    var mediumView: some View {
        HStack(spacing: 16) {
            // Left: ETA
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "car.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(red: 0.608, green: 0.557, blue: 0.769))
                    Text(entry.commuteName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                if let eta = entry.etaMinutes {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(eta)")
                            .font(.system(size: 42, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text("min")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    if entry.isStale, let updated = entry.etaUpdatedAt {
                        Text("as of \(updated, style: .time)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                } else {
                    Text("No ETA yet")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            // Right: destination and status
            VStack(alignment: .trailing, spacing: 8) {
                if entry.isNavigating {
                    Text("Navigating")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.608, green: 0.557, blue: 0.769))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.608, green: 0.557, blue: 0.769).opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()

                if !entry.destinationName.isEmpty {
                    Text("to \(entry.destinationName)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(4)
    }
}
