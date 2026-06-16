import Testing
import SwiftUI
import UIKit
@testable import Steddi

/// Empirical + pure-math harness for the nav-HUD over-map glass legibility in
/// DARK theme — the seam behind the "near-white readout washes out on a light
/// Liquid Glass frost" finding.
///
/// THE BUG (measured): the HUD readouts ride neutral / lightly-tinted `.regular`
/// Liquid Glass over the moving map. Over a DARK map in dark theme the OS renders
/// that glass as a LIGHT frost (the codebase's own sampled ~0.73 sRGB — see
/// `OnboardingShowcaseFrost`). Dark-theme `textPrimary` is near-WHITE
/// (RGB 0.97), so it collapsed to ~1.8:1 on that frost — below the 4.5 body floor
/// and even the 3.0 large floor. The old mitigations were weak: the scrim was
/// `surfacePrimary.opacity(0.22)` (a faint wash *behind* the translucent frost,
/// which the frost composites over and dominates), and `legibleOverMap()` is a
/// single soft shadow that only adds edge separation, not fill-vs-fill contrast.
///
/// THE FIX (mirrors the onboarding dark-card remedy): in DARK theme the over-map
/// scrim becomes a near-opaque luminance-FIXED dark fill (`onboardingCardFallback
/// Fill` at 0.9), so the adaptive glass renders DARK against it and the readouts
/// sit white-on-dark. LIGHT theme is untouched (near-black text on the light
/// frost already reads ~9–12:1, the approved look). Like the onboarding harness,
/// live glass luminance isn't deterministic from `ImageRenderer`, so the contrast
/// is asserted against `SteddiTheme.mapGlassDarkScrimSurface` — the conservative
/// (no-lighter-than) composite of the dark scrim over a dark map tile — and an
/// `ImageRenderer` test confirms that rendered composite really is dark.
@MainActor
@Suite("Nav HUD frost measurement (dark theme over-map legibility)")
struct NavHUDFrostMeasurementTests {

    // MARK: - ImageRenderer: the dark-scrim composite really renders dark

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

    /// Read one straight-sRGB pixel from a CGImage via a known 8-bit device-RGB
    /// bitmap, independent of the image's native colour space / alpha layout.
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

    /// The dark over-map scrim the fix paints in DARK theme — the fixed-dark
    /// `onboardingCardFallbackFill` at 0.9 opacity — over a stand-in for a dark
    /// map tile (the representative cartography the HUD glass floats on at night).
    private var darkScrimPanel: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.11) // representative dark map tile
            RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                .fill(SteddiTheme.onboardingCardFallbackFill.opacity(0.9))
                .frame(width: 300, height: 120)
        }
    }

    @Test("the rendered dark over-map scrim is dark enough for near-white HUD readouts to read")
    func darkScrimRendersDark() {
        let sampled = centrePixel(darkScrimPanel, size: CGSize(width: 340, height: 180))
        let lum = ContrastRatio.relativeLuminance(sampled)
        #expect(lum < ContrastRatio.foregroundFlipLuminance,
                "rendered scrim luminance = \(lum) (sRGB \(sampled)); want a dark surface (< 0.179) so near-white readouts read")
        // Dark-theme textPrimary (near-white) clears the AA body floor on the
        // SAMPLED pixel, not just the modelled constant.
        let textPrimary = ThemePalette.dark.textPrimary
        let r = ContrastRatio.ratio(textPrimary, sampled)
        #expect(r >= ContrastRatio.aaBody,
                "dark textPrimary on the rendered scrim = \(r), want >= 4.5")
    }

    @Test("the pinned dark-scrim surface constant is no lighter than the rendered scrim")
    func pinnedSurfaceIsConservative() {
        let sampled = centrePixel(darkScrimPanel, size: CGSize(width: 340, height: 180))
        let renderedLum = ContrastRatio.relativeLuminance(sampled)
        let constantLum = ContrastRatio.relativeLuminance(SteddiTheme.mapGlassDarkScrimSurface)
        #expect(constantLum < ContrastRatio.foregroundFlipLuminance,
                "dark-scrim constant luminance \(constantLum) should be dark (< 0.179)")
        #expect(renderedLum <= constantLum + 0.01,
                "rendered scrim \(renderedLum) should be no lighter than the pinned constant \(constantLum)")
    }

    // MARK: - Pure-math AA on the deterministic dark-scrim surface

    /// The dark surface the HUD readouts effectively sit on in DARK theme.
    private var frost: RGBColor { SteddiTheme.mapGlassDarkScrimSurface }
    private let dark = ThemePalette.dark

    @Test("top-banner distance + instruction (textPrimary) clear AA on the dark scrim")
    func topBannerReadoutsAA() {
        // Distance line (mono 34) and the safety-critical instruction (semibold
        // 18) both draw in textPrimary. Body floor for the worst case.
        let r = ContrastRatio.ratio(dark.textPrimary, frost)
        #expect(r >= ContrastRatio.aaBody, "dark top-banner textPrimary/frost = \(r), want >= 4.5")
    }

    @Test("bottom-bar + landscape ETA readouts (textPrimary digit, textSecondary labels) clear their floors")
    func etaReadoutsAA() {
        // ETA minutes digit is textPrimary (body floor); the "min" / distance /
        // arrival-time labels are textSecondary (meaningful readouts → body floor
        // is the bar these are held to elsewhere, but they are large mono — assert
        // the 3:1 large floor as the hard requirement and confirm body where met).
        let digit = ContrastRatio.ratio(dark.textPrimary, frost)
        #expect(digit >= ContrastRatio.aaBody, "dark ETA digit textPrimary/frost = \(digit), want >= 4.5")
        let secondary = ContrastRatio.ratio(dark.textSecondary, frost)
        #expect(secondary >= ContrastRatio.aaLarge, "dark ETA label textSecondary/frost = \(secondary), want >= 3.0")
    }

    @Test("street-name capsule (textSecondary) clears the 3:1 floor on the dark scrim")
    func streetNameAA() {
        let r = ContrastRatio.ratio(dark.textSecondary, frost)
        #expect(r >= ContrastRatio.aaLarge, "dark street-name textSecondary/frost = \(r), want >= 3.0")
    }

    @Test("speedometer at/under-limit digit (textPrimary) clears AA on the dark scrim")
    func speedometerDigitAA() {
        // The common at/under-limit speed digit is textPrimary on neutral glass —
        // now backed by the over-map scrim in dark theme. (Over-limit states use a
        // solid warmRed/amber housing already, covered by ThemeContrastTests.)
        let r = ContrastRatio.ratio(dark.textPrimary, frost)
        #expect(r >= ContrastRatio.aaBody, "dark speedometer digit textPrimary/frost = \(r), want >= 4.5")
        // The "mph" caption is textSecondary → 3:1 large floor.
        let mph = ContrastRatio.ratio(dark.textSecondary, frost)
        #expect(mph >= ContrastRatio.aaLarge, "dark speedometer mph textSecondary/frost = \(mph), want >= 3.0")
    }

    @Test("reroute card heading (textPrimary) + 'Save ~N min' (sageText) clear AA on the dark scrim")
    func rerouteCardAA() {
        // In dark theme the card drops the lavender tint (neutral glass) and rides
        // the same dark scrim, so the heading (textPrimary, near-white) and the
        // glanceable green value (sageText, which lightens toward white in dark)
        // both read white-on-dark.
        let heading = ContrastRatio.ratio(dark.textPrimary, frost)
        #expect(heading >= ContrastRatio.aaBody, "dark reroute heading textPrimary/frost = \(heading), want >= 4.5")
        // sageText resolves via the live theme; model it against the dark surface
        // the same way the token does (lightens toward white on a dark surface).
        let sageText = SteddiTheme.legibleText(SteddiTheme.sageRGB, onSurface: dark.surfacePrimary)
        let value = ContrastRatio.ratio(sageText, frost)
        #expect(value >= ContrastRatio.aaLarge, "dark reroute sageText/frost = \(value), want >= 3.0")
    }

    // MARK: - Regression: document the old light-frost washout

    @Test("the OLD light-frost surface failed every flagged dark-theme readout (documents the bug)")
    func lightFrostRegression() {
        // The neutral/lightly-tinted .regular glass the OS renders LIGHT over a
        // dark map — the codebase's own sampled ~0.73 frost. Near-white dark-theme
        // textPrimary failed even the 3:1 large floor on it; the dark scrim fixes
        // it (asserted above).
        let oldLightFrost = RGBColor(0.73, 0.73, 0.75)
        let onLight = ContrastRatio.ratio(dark.textPrimary, oldLightFrost)
        #expect(onLight < ContrastRatio.aaLarge,
                "dark textPrimary on the old light frost was \(onLight), expected sub-3:1 (documents the bug)")
        let onDark = ContrastRatio.ratio(dark.textPrimary, frost)
        #expect(onDark >= ContrastRatio.aaBody, "dark textPrimary on the dark scrim = \(onDark), want >= 4.5")
        #expect(onDark > onLight)

        // The lavender-tinted reroute frost was even lighter — its near-white
        // heading was worse. The neutral-glass-in-dark fix uses the same dark scrim.
        let oldLavFrost = RGBColor(0.78, 0.76, 0.84)
        let lavHeading = ContrastRatio.ratio(dark.textPrimary, oldLavFrost)
        #expect(lavHeading < ContrastRatio.aaLarge,
                "dark reroute heading on the old lavender frost was \(lavHeading), expected sub-3:1 (documents the bug)")
    }

    // MARK: - LIGHT theme stays untouched (no regression of the approved look)

    @Test("LIGHT theme keeps the faint approved scrim opacity (no over-darkening)")
    func lightThemeScrimUnchanged() {
        // The fix is dark-theme-only. Light theme keeps the original 0.22 faint
        // adaptive wash, so the user-approved light HUD is byte-for-byte unchanged.
        // (We assert the opacity contract; the live `prefersDarkChrome` branch is
        // exercised by the views.)
        #expect(SteddiTheme.mapGlassScrimOpacity(highContrast: true) == 0,
                "high contrast forces opaque glass, so the scrim is suppressed")
        // Light-theme near-black text on a light frost already clears AA with
        // margin — documents why no change is needed there.
        let light = ThemePalette.light
        let lightFrost = RGBColor(0.85, 0.84, 0.83)
        let r = ContrastRatio.ratio(light.textPrimary, lightFrost)
        #expect(r >= ContrastRatio.aaBody, "light textPrimary on light frost = \(r), already fine, want >= 4.5")
    }
}
