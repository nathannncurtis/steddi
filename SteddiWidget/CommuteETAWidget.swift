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

/// How long a "navigating" entry may go without a fresh live ETA write before
/// the widget stops presenting it as a live drive (seconds).
///
/// A live nav session writes a new ETA on a tight cadence (every GPS update /
/// live sync), so a navigating flag whose last ETA timestamp is older than this
/// means the session almost certainly died (OOM / watchdog kill) without running
/// any teardown path — the App Group still says `isNavigating == true` with a
/// frozen near-arrival ETA. The writer only reconciles this at the next app
/// launch (NavigationStateManager.reconcileWidgetSessionAtLaunch); until then the
/// widget would render a phantom "Navigating" pill with a dead ETA. Bounding it
/// here caps that window to a couple of minutes instead of "until next launch".
private let navigatingStalenessWindow: TimeInterval = 3 * 60

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

    /// Whether this entry represents a *live* navigation session — the navigating
    /// flag is set AND the last live ETA write is recent enough to trust.
    ///
    /// A live drive writes a fresh ETA on a tight cadence, so a navigating flag
    /// whose last timestamp is missing or older than `navigatingStalenessWindow`
    /// is a dead session: the app was killed mid-drive (OOM / watchdog) before any
    /// teardown ran, leaving `isNavigating == true` with a frozen ETA, and the
    /// next-launch reconcile (NavigationStateManager.reconcileWidgetSessionAtLaunch)
    /// hasn't run yet. The widget must NOT present that as a live drive, so it
    /// independently bounds the staleness here rather than trusting the flag.
    var isLiveNavigating: Bool {
        guard isNavigating else { return false }
        guard let updated = etaUpdatedAt else { return false }
        return date.timeIntervalSince(updated) <= navigatingStalenessWindow
    }

    /// The ETA is considered stale (worth labeling as last-known) when it isn't
    /// a live navigation value and isn't a verifiably-fresh idle value.
    ///
    /// Robustness note (coordinates with NavigationStateManager.clearWidgetSession,
    /// owned elsewhere): when a drive ends, the last live write left a ~near-arrival
    /// ETA (e.g. 1–2 min) with a *recent* timestamp and `isNavigating` flips to
    /// false — that terminal value must NOT be presented as the upcoming-commute
    /// ETA. The writer side clears/recomputes the idle ETA on nav end; the widget
    /// must stay correct regardless of exactly how it does so. So:
    /// - Live-navigating (flag set AND ETA write recent): never stale (the live
    ///   ETA is authoritative).
    /// - A stuck navigating flag (set but the ETA write is old/missing) is a dead
    ///   session: stale *immediately* (the moment it stops being live). The live
    ///   nav cadence is tight, so once the navigating write ages past
    ///   `navigatingStalenessWindow` the value is a frozen, likely near-arrival ETA
    ///   from a killed drive — bounding it by the much wider idle `etaFreshnessWindow`
    ///   here would leave it shown as a plain current number (no pill, no "as of …"
    ///   qualifier) for up to ~27 min after the live pill is retired. Treating it as
    ///   stale right away qualifies it as last-known instead of implying it is fresh.
    /// - Not navigating with no timestamp: treat as stale — we can't prove the
    ///   value is a fresh pre-drive computation, so label it rather than imply it
    ///   is a live current ETA.
    /// - Not navigating with a timestamp: stale once outside the freshness window.
    /// A cleared ETA (see `etaMinutes`) renders as "No ETA yet" and never reaches
    /// the stale path.
    var isStale: Bool {
        if isLiveNavigating { return false }
        // A navigating flag that isn't live is a dead/stale session (OOM/watchdog
        // kill before teardown): qualify it the instant the live window lapses
        // rather than deferring to the wider idle freshness window.
        if isNavigating { return true }
        guard let updated = etaUpdatedAt else { return true }
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
        let now = Date.now
        let entry = currentEntry()
        var entries = [entry]

        // The freshness/liveness labels are time-based state transitions, but
        // they're computed against each entry's own `date`. With a single entry
        // frozen at `now`, a value that crosses a staleness boundary mid-cycle
        // wouldn't flip until the next ~15-min reload (up to ~15 min late). Emit a
        // second entry dated exactly at the next crossing instant so the widget
        // re-renders right when the state changes.
        //
        // - Navigating: the crossing is when a stuck flag from an OOM/watchdog
        //   kill stops being "live" (etaUpdatedAt + navigatingStalenessWindow), so
        //   the phantom "Navigating" pill is retired without waiting for an app
        //   launch.
        // - Idle: the crossing is when a fresh idle ETA goes stale
        //   (etaUpdatedAt + etaFreshnessWindow) and flips to the "as of …" label.
        if let updated = entry.etaUpdatedAt {
            let window = entry.isNavigating ? navigatingStalenessWindow : etaFreshnessWindow
            let crossingAt = updated.addingTimeInterval(window)
            if crossingAt > now {
                entries.append(CommuteETAEntry(
                    date: crossingAt,
                    commuteName: entry.commuteName,
                    etaMinutes: entry.etaMinutes,
                    destinationName: entry.destinationName,
                    isNavigating: entry.isNavigating,
                    etaUpdatedAt: entry.etaUpdatedAt
                ))
            }
        }

        // Refresh every 15 minutes so the freshness label/relative age advances
        // even when the app doesn't write new defaults in between.
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        let timeline = Timeline(entries: entries, policy: .after(nextUpdate))
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
            // 0 is the cleared/idle sentinel (e.g. clearWidgetSession on nav end);
            // any non-positive value means "no ETA to show" rather than a real one.
            etaMinutes: eta > 0 ? eta : nil,
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
                // Only show the live "Navigating" pill for a session whose ETA is
                // still being written; a stuck flag from an OOM/watchdog kill is
                // NOT live (see CommuteETAEntry.isLiveNavigating).
                if entry.isLiveNavigating {
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
