import Testing
import SwiftUI
import UIKit
@testable import Steddi

/// Guards the hit area on the in-nav "End" button — the destructive CTA that
/// ends turn-by-turn guidance.
///
/// The visible button is sized purely by its 17pt label plus modest padding; the
/// in-nav LANDSCAPE variant used `.padding(.vertical, 10)` and laid out at ~40pt
/// tall under the default control scale — below Apple's 44×44pt HIG minimum for
/// the single most consequential mid-drive control (a near-miss while driving is
/// bad). The fix pins a 44pt floor inside `SteddiDestructiveButtonStyle`
/// (`.frame(minWidth: 44, minHeight: 44).contentShape(Capsule())`) so the hit
/// target can never regress, mirroring the floors HomeView / the sheet tabs /
/// NowPlaying play-pause already enforce. Because the floor lives in the style,
/// testing the style directly covers BOTH nav layouts (and every other
/// destructive CTA) at once.
///
/// We render the isolated buttons through a `UIHostingController` and measure the
/// size SwiftUI lays them out at; the style's outer 44pt frame is what the
/// hit-testable `contentShape` is pinned to.
@MainActor
@Suite("In-nav End button tap target")
struct NavEndButtonTapTargetTests {

    /// The laid-out size of a view given an unconstrained proposal.
    private func laidOutSize<V: View>(_ view: V) -> CGSize {
        let host = UIHostingController(rootView: view)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: .max, height: .max))
    }

    /// Mirrors the landscape End button (SteddiNavOverlay landscape layout): the
    /// 17pt label with the tighter 10pt vertical padding that produced the ~40pt
    /// pre-fix height. This is the worst case.
    @Test("landscape End button is at least 44x44pt")
    func landscapeEndMeetsMinimumTapTarget() {
        let button = Button("End") {}
            .font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .buttonStyle(.steddiDestructive)
        let size = laidOutSize(button)
        #expect(size.width >= 44)
        #expect(size.height >= 44)
    }

    /// Mirrors the portrait End button (the looser 12pt vertical padding). It was
    /// borderline pre-fix; the style floor keeps it comfortably above 44pt.
    @Test("portrait End button is at least 44x44pt")
    func portraitEndMeetsMinimumTapTarget() {
        let button = Button("End") {}
            .font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .buttonStyle(.steddiDestructive)
        let size = laidOutSize(button)
        #expect(size.width >= 44)
        #expect(size.height >= 44)
    }
}
