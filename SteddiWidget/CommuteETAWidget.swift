import WidgetKit
import SwiftUI

/// Data for the commute ETA widget
struct CommuteETAEntry: TimelineEntry {
    let date: Date
    let commuteName: String
    let etaMinutes: Int?
    let destinationName: String
    let isNavigating: Bool
}

/// Timeline provider — reads shared data from App Group
struct CommuteETAProvider: TimelineProvider {
    private let defaults = UserDefaults(suiteName: "group.to.nathancurtis.steddi")

    func placeholder(in context: Context) -> CommuteETAEntry {
        CommuteETAEntry(date: .now, commuteName: "Work", etaMinutes: 35, destinationName: "Office", isNavigating: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (CommuteETAEntry) -> Void) {
        let entry = currentEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CommuteETAEntry>) -> Void) {
        let entry = currentEntry()
        // Refresh every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func currentEntry() -> CommuteETAEntry {
        let name = defaults?.string(forKey: "widget.commuteName") ?? "Commute"
        let eta = defaults?.integer(forKey: "widget.etaMinutes")
        let dest = defaults?.string(forKey: "widget.destinationName") ?? ""
        let isNav = defaults?.bool(forKey: "widget.isNavigating") ?? false

        return CommuteETAEntry(
            date: .now,
            commuteName: name,
            etaMinutes: eta == 0 ? nil : eta,
            destinationName: dest,
            isNavigating: isNav
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
            } else {
                Text("Tap to update")
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
                } else {
                    Text("Tap to update")
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
