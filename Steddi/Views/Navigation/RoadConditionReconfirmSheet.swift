import SwiftUI
import SwiftData

/// Post-arrival "still there?" prompt. Shown when the just-driven route has road
/// conditions whose last confirmation is older than the 14-day reconfirm window.
///
/// Presents one condition at a time with three fast chips:
/// - **Yes** — still there. Resets the decay timer (`updateConfirmation`).
/// - **Gone** — fixed. Soft-deletes it (`expireCondition`).
/// - **Skip** — no opinion. Leaves it untouched; it will prompt again next drive.
///
/// Skip is always available and the whole sheet is dismissible, so the flow can
/// never trap the driver. When the last condition is handled the sheet dismisses.
struct RoadConditionReconfirmSheet: View {
    /// Stale conditions to walk through, oldest-first (as produced by
    /// `RoadConditionService.staleConditionsOnRoute`).
    let conditions: [RoadCondition]
    /// Service that owns the confirm/expire mutations.
    var service: RoadConditionService = .shared

    @Environment(\.dismiss) private var dismiss
    @AppStorage("accentColor") private var accentColor = "lavender"

    @State private var currentIndex = 0

    private var current: RoadCondition? {
        guard currentIndex < conditions.count else { return nil }
        return conditions[currentIndex]
    }

    var body: some View {
        let _ = accentColor // re-render on accent change
        NavigationStack {
            VStack(spacing: 0) {
                if let condition = current {
                    promptBody(condition)
                } else {
                    // Nothing (or nothing left) to reconfirm — dismiss promptly.
                    Color.clear.onAppear { dismiss() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SteddiTheme.surfacePrimary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(SteddiTheme.textMuted)
                }
            }
        }
    }

    private func promptBody(_ condition: RoadCondition) -> some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: condition.kind.icon)
                .font(.system(size: 44))
                .foregroundStyle(condition.kind.color)
                .padding(.bottom, 20)

            Text(promptTitle(for: condition))
                .font(SteddiTheme.heading(20))
                .foregroundStyle(SteddiTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text(ageDescription(for: condition))
                .font(SteddiTheme.body(14))
                .foregroundStyle(SteddiTheme.textMuted)
                .padding(.top, 8)

            if let note = condition.note, !note.isEmpty {
                Text(note)
                    .font(SteddiTheme.body(13))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.horizontal, 32)
            }

            if conditions.count > 1 {
                Text("\(currentIndex + 1) of \(conditions.count)")
                    .font(SteddiTheme.body(12))
                    .foregroundStyle(SteddiTheme.textMuted)
                    .padding(.top, 12)
            }

            Spacer()

            HStack(spacing: 10) {
                actionChip("Yes", systemImage: "checkmark", fill: SteddiTheme.sageRGB) {
                    service.updateConfirmation(condition)
                    advance()
                }
                actionChip("Gone", systemImage: "xmark", fill: SteddiTheme.warmRedRGB) {
                    service.expireCondition(condition)
                    advance()
                }
                // Muted "no opinion" chip — neutral surface fill, secondary label.
                actionChip("Skip", systemImage: "arrow.right", fill: nil) {
                    advance()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    /// One reconfirm chip. `fill` is the semantic fill RGB for the affirmative/
    /// negative chips; `nil` renders the muted "Skip" chip on the neutral surface.
    private func actionChip(
        _ title: String,
        systemImage: String,
        fill: RGBColor?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(SteddiTheme.body(14))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            // On-fill label: the AA-correct contrasting foreground for the fill
            // (never hardcoded white — white-on-sage 2.45:1, white-on-warmRed
            // 3.78:1, both fail AA). The muted Skip chip uses textSecondary on the
            // neutral surface, which already clears AA.
            .foregroundStyle(fill.map { SteddiTheme.contrastingForeground(on: $0) } ?? SteddiTheme.textSecondary)
            .background(fill?.color ?? SteddiTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Move to the next stale condition, dismissing when none remain.
    private func advance() {
        if currentIndex + 1 < conditions.count {
            withAnimation(.easeInOut(duration: 0.2)) { currentIndex += 1 }
        } else {
            dismiss()
        }
    }

    private func promptTitle(for condition: RoadCondition) -> String {
        let road = condition.route?.name.map { " on \($0)" } ?? ""
        return "You passed \(article(condition.kind)) \(condition.kind.displayName.lowercased())\(road) — still there?"
    }

    private func article(_ kind: RoadConditionKind) -> String {
        "aeiou".contains(kind.displayName.lowercased().first ?? "x") ? "an" : "a"
    }

    private func ageDescription(for condition: RoadCondition) -> String {
        let days = condition.daysSinceConfirmed()
        if days <= 0 { return "Reported today" }
        if days == 1 { return "Last confirmed 1 day ago" }
        return "Last confirmed \(days) days ago"
    }
}
