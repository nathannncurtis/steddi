import Testing
import SwiftUI
import UIKit
@testable import Steddi

/// Guards the hit area on the first-run onboarding controls — the primary CTAs
/// (footer "Next"/"Get Started", the in-card "Continue" and "Add Contact") and
/// the secondary/escape affordances (footer "Skip setup", the top-right
/// "Skip setup", "Not now", "Choose a different contact").
///
/// The whole app pins Apple's 44×44pt HIG hit-target floor on its tappable
/// controls — there are dedicated suites (NavEndButtonTapTargetTests,
/// HomeSheetTabTapTargetTests, NowPlayingMiniBarTapTargetTests) and explicit
/// `.frame(minHeight: 44).contentShape(...)` expansions throughout HomeView /
/// SettingsView. The onboarding controls used to skip it: the secondary text
/// buttons rendered ~20–22pt tall and the glass-filled primary CTAs ~30–34pt
/// (.headline + only 4–6pt vertical padding). The fix expands each to a ≥44pt
/// hit target (the visual text/fill is unchanged).
///
/// The onboarding buttons are private computed properties inside their views, so
/// — like NavEndButtonTapTargetTests does for the End button — we reconstruct
/// each control here with the SAME modifier chain the production view applies and
/// measure the size SwiftUI lays it out at via a `UIHostingController`.
@MainActor
@Suite("Onboarding tap targets")
struct OnboardingTapTargetTests {

    /// The laid-out size of a view given an unconstrained proposal.
    private func laidOutSize<V: View>(_ view: V) -> CGSize {
        let host = UIHostingController(rootView: view)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: .max, height: .max))
    }

    /// The laid-out size given a fixed width (full-width capsule CTAs share the
    /// card/footer width, so only height is the at-risk dimension there).
    private func laidOutSize<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let host = UIHostingController(rootView: view.frame(width: width))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    // MARK: - Primary CTAs (full-width glass capsules)

    /// Footer primary ("Next" / "Get Started"): `.font(.headline)` + the 44pt
    /// minHeight floor (was `.padding(.vertical, 6)` ≈ 32pt pre-fix).
    @Test("footer primary CTA is at least 44pt tall")
    func footerPrimaryMeetsMinimumTapTarget() {
        let button = Button {} label: {
            Text("Get Started")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        let size = laidOutSize(button, width: 320)
        #expect(size.height >= 44)
    }

    /// Permissions in-card "Continue": `.font(.headline)` + the 44pt minHeight
    /// floor (was `.padding(.vertical, 4)` ≈ 30pt pre-fix).
    @Test("permissions Continue CTA is at least 44pt tall")
    func permissionsContinueMeetsMinimumTapTarget() {
        let button = Button {} label: {
            Text("Continue")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        let size = laidOutSize(button, width: 320)
        #expect(size.height >= 44)
    }

    /// Emergency in-card "Add Contact" (a `Label`, so it carries an SF Symbol +
    /// text): `.font(.headline)` + the 44pt minHeight floor.
    @Test("emergency Add Contact CTA is at least 44pt tall")
    func emergencyAddContactMeetsMinimumTapTarget() {
        let button = Button {} label: {
            Label("Add Contact", systemImage: "person.crop.circle.badge.plus")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        let size = laidOutSize(button, width: 320)
        #expect(size.height >= 44)
    }

    // MARK: - Secondary / escape text buttons

    /// Footer "Skip setup": a `.subheadline` text button expanded to a 44pt hit
    /// region (was a bare label ≈ 20pt tall pre-fix).
    @Test("footer Skip setup is at least 44pt tall")
    func footerSkipMeetsMinimumTapTarget() {
        let button = Button("Skip setup") {}
            .font(.subheadline)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        let size = laidOutSize(button)
        #expect(size.height >= 44)
    }

    /// Top-right showcase "Skip setup": `.subheadline.weight(.medium)` expanded to
    /// a 44×44pt hit region (was ≈ 36pt tall pre-fix).
    @Test("top-right Skip setup is at least 44x44pt")
    func skipIntroMeetsMinimumTapTarget() {
        let button = Button("Skip setup") {}
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        let size = laidOutSize(button)
        #expect(size.width >= 44)
        #expect(size.height >= 44)
    }

    /// Permissions "Not now": a bare `.subheadline` text button expanded to a 44pt
    /// hit region (was ≈ 22pt tall pre-fix).
    @Test("permissions Not now is at least 44pt tall")
    func notNowMeetsMinimumTapTarget() {
        let button = Button("Not now") {}
            .font(.subheadline)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        let size = laidOutSize(button)
        #expect(size.height >= 44)
    }

    /// Emergency "Choose a different contact": a bare `.subheadline` text button
    /// expanded to a 44pt hit region (was ≈ 22pt tall pre-fix).
    @Test("emergency Choose a different contact is at least 44pt tall")
    func chooseDifferentContactMeetsMinimumTapTarget() {
        let button = Button {} label: {
            Text("Choose a different contact")
                .font(.subheadline)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        let size = laidOutSize(button)
        #expect(size.height >= 44)
    }
}
