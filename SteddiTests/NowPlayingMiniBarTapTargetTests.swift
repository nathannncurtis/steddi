import Testing
import SwiftUI
import UIKit
@testable import Steddi

/// Guards the play/pause hit area on the in-nav NowPlaying mini-bar.
///
/// The button's *visible* glyph circle is intentionally smaller than 44pt
/// (`height - 14` in the portrait/non-compact variant = 38pt; the compact
/// variant's circle is 32pt), but the tappable area must still meet Apple's
/// 44×44pt HIG minimum — this is the play/pause control used while driving, and
/// a near-miss otherwise falls through to the bar's tap gesture, launching the
/// music app out of navigation. The fix wraps the visual circle in a
/// `.frame(width: 44, height: 44).contentShape(Circle())`, the same pattern
/// HomeView uses for its sub-44 glyph buttons.
///
/// We render the isolated `playPauseButton` through a `UIHostingController` and
/// measure the size SwiftUI lays it out at; the outer 44pt frame is what the
/// hit-testable `contentShape` is pinned to.
@MainActor
@Suite("NowPlayingMiniBar tap target")
struct NowPlayingMiniBarTapTargetTests {

    /// The laid-out size of a view when given an unconstrained proposal.
    private func laidOutSize<V: View>(_ view: V) -> CGSize {
        let host = UIHostingController(rootView: view)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: .max, height: .max))
    }

    @Test("portrait play/pause button is at least 44x44pt")
    func portraitButtonMeetsMinimumTapTarget() {
        let size = laidOutSize(NowPlayingMiniBar().playPauseButton)
        #expect(size.width >= 44)
        #expect(size.height >= 44)
    }

    @Test("compact play/pause button is at least 44x44pt")
    func compactButtonMeetsMinimumTapTarget() {
        let size = laidOutSize(NowPlayingMiniBar(compact: true).playPauseButton)
        #expect(size.width >= 44)
        #expect(size.height >= 44)
    }
}
