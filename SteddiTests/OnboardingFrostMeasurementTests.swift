import Testing
import SwiftUI
import UIKit
@testable import Steddi

/// Empirical measurement harness for the onboarding showcase/ask beat card
/// surface — the seam behind the recurring onboarding-legibility findings.
///
/// The morphing `OnboardingShowpieceCard` renders its non-theme beats
/// (routeRules / turnByTurn / permissions / emergency) inside neutral `.regular`
/// Liquid Glass over the fixed near-black cinematic backdrop. Live glass
/// luminance is not deterministic from code: over the dark backdrop the OS
/// renders that neutral glass as a noticeably LIGHT frost (~0.73 sRGB, sampled
/// from a real device render), so the fixed-white copy collapsed to ~1.9:1 and
/// the accent glyphs to ~1.65:1 — below the AA floors.
///
/// THE FIX (dark cards): `OnboardingShowpieceCard` paints a deterministic DARK
/// scrim behind the content of every non-theme beat, so the copy + glyphs sit on
/// a reliably dark surface (white-on-dark, like the hero). That scrim is what
/// `OnboardingShowcaseFrost.surface` is the conservative composite of, and unlike
/// live glass it is fully renderable: this harness uses `ImageRenderer` to
/// rasterise the dark scrim over the backdrop and SAMPLE the actual composited
/// surface luminance, confirming the surface the copy/glyphs rest on is dark
/// enough for every element to clear AA. (The pure-math contrast assertions in
/// `ThemeContrastTests.onboarding*` then guard the per-element ratios against
/// that pinned surface.)
@MainActor
@Suite("Onboarding frost measurement (ImageRenderer)")
struct OnboardingFrostMeasurementTests {

    /// Render `view` at `size` and return the straight-sRGB pixel at its centre.
    private func centrePixel<V: View>(_ view: V, size: CGSize) -> RGBColor {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let ui = renderer.uiImage, let cg = ui.cgImage else {
            Issue.record("ImageRenderer produced no image")
            return RGBColor(0, 0, 0)
        }
        return pixel(cg, x: cg.width / 2, y: cg.height / 2)
    }

    /// Read one straight-sRGB pixel from a CGImage by drawing it into a known
    /// 8-bit RGBA bitmap (device-RGB), so the sample is independent of the
    /// image's native colour space / alpha layout.
    private func pixel(_ cg: CGImage, x: Int, y: Int) -> RGBColor {
        var data = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            Issue.record("could not create sampling context")
            return RGBColor(0, 0, 0)
        }
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return RGBColor(Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }

    /// The dark scrim the fix paints behind the content of every non-theme beat
    /// (`onboardingCardFallbackFill` at 0.94 opacity), over a stand-in for the
    /// near-black cinematic backdrop — the worst case for darkness is the
    /// LIGHTEST plausible glass beneath the scrim, so the backdrop here is the
    /// representative dark gradient the real card floats on.
    private var darkScrimCard: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.92), Color.black.opacity(0.96)],
                startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: SteddiTheme.radiusLarge)
                .fill(SteddiTheme.onboardingCardFallbackFill.opacity(0.94))
                .frame(width: 300, height: 200)
        }
    }

    @Test("the rendered dark-scrim card surface is dark enough for white copy to read")
    func darkScrimRendersDark() {
        // Sample the actual composited card surface. It must render DARK — far
        // below the 0.179 WCAG flip luminance — so the fixed-white onboarding
        // copy/glyphs read white-on-dark like the hero.
        let sampled = centrePixel(darkScrimCard, size: CGSize(width: 340, height: 260))
        let lum = ContrastRatio.relativeLuminance(sampled)
        #expect(lum < ContrastRatio.foregroundFlipLuminance,
                "rendered card surface luminance = \(lum) (sRGB \(sampled)); want a dark surface (< 0.179) so white copy reads")
        // And white primary copy clears the AA body floor against the SAMPLED
        // pixel, not just the modelled constant.
        let whiteOnSampled = ContrastRatio.ratio(RGBColor(1, 1, 1), sampled)
        #expect(whiteOnSampled >= ContrastRatio.aaBody,
                "white copy on the rendered surface = \(whiteOnSampled), want >= 4.5")
    }

    @Test("the pinned frost surface constant is no lighter than the rendered scrim")
    func pinnedSurfaceIsConservative() {
        // `OnboardingShowcaseFrost.surface` is the value the contrast math is
        // sized against; it must be a worst-case (>= as light as) the real
        // rendered scrim, so every modelled ratio is a lower bound the render
        // beats. The constant is dark (luminance well below the flip), and the
        // rendered scrim is darker still.
        let sampled = centrePixel(darkScrimCard, size: CGSize(width: 340, height: 260))
        let renderedLum = ContrastRatio.relativeLuminance(sampled)
        let constantLum = ContrastRatio.relativeLuminance(OnboardingShowcaseFrost.surface)
        #expect(constantLum < ContrastRatio.foregroundFlipLuminance,
                "frost constant luminance \(constantLum) should be dark (< 0.179)")
        #expect(renderedLum <= constantLum + 0.01,
                "rendered scrim \(renderedLum) should be no lighter than the pinned constant \(constantLum)")
    }
}
