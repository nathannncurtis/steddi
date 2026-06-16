import Testing
import SwiftUI
import UIKit
@testable import Steddi

/// Guards the hit area on the Home Commutes/Places/Trips tab labels — the
/// portrait bottom-sheet tab bar and the landscape sidebar tabs.
///
/// These are primary top-level navigation used constantly. Their *visible* label
/// is just a heading-font Text in modest vertical padding (well under 44pt), but
/// the tappable area must still meet Apple's 44×44pt HIG minimum. `HomeSheetTabLabel`
/// wraps the label (and any active pill) in `.frame(minHeight: 44).contentShape(Rectangle())`,
/// the same pattern HomeView uses for its gear / New Commute buttons and the
/// NowPlaying play/pause control.
///
/// We render the isolated label through a `UIHostingController` and measure the
/// laid-out height; the outer 44pt frame is what the hit-testable `contentShape`
/// is pinned to. Width is `maxWidth: .infinity` (the tabs share the bar width),
/// so only height is the at-risk dimension.
@MainActor
@Suite("Home sheet tab tap target")
struct HomeSheetTabTapTargetTests {

    /// The laid-out size of a view given a fixed-width, unconstrained-height
    /// proposal (the tabs always get a finite shared width from the bar/sidebar).
    private func laidOutSize<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let host = UIHostingController(rootView: view.frame(width: width))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: .max))
    }

    @Test("portrait bottom-sheet tab label is at least 44pt tall")
    func portraitTabMeetsMinimumTapTarget() {
        // Portrait bar: heading(14), inactive (no pill background).
        let label = HomeSheetTabLabel(
            title: "Commutes",
            font: SteddiTheme.heading(14),
            color: SteddiTheme.textSecondary
        ) { EmptyView() }
        let size = laidOutSize(label, width: 120)
        #expect(size.height >= 44)
    }

    @Test("portrait active tab label (with pill) is at least 44pt tall")
    func portraitActiveTabMeetsMinimumTapTarget() {
        // Active tab carries the accent-glass pill background; the 44pt expansion
        // is applied after it, so the hit target must still clear 44pt.
        let label = HomeSheetTabLabel(
            title: "Commutes",
            font: SteddiTheme.heading(14),
            color: SteddiTheme.onAccent
        ) {
            Capsule().fill(SteddiTheme.accentBrand)
        }
        let size = laidOutSize(label, width: 120)
        #expect(size.height >= 44)
    }

    @Test("landscape sidebar tab label is at least 44pt tall")
    func landscapeTabMeetsMinimumTapTarget() {
        // Sidebar: smaller heading(12), no pill.
        let label = HomeSheetTabLabel(
            title: "Commutes",
            font: SteddiTheme.heading(12),
            color: SteddiTheme.textSecondary
        ) { EmptyView() }
        let size = laidOutSize(label, width: 90)
        #expect(size.height >= 44)
    }
}
