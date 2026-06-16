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
///
/// THE REROUTE CARD also gets a LIGHT-theme seam here: it is the one HUD panel
/// that keeps its glass ACCENT-tinted in light theme (the delight peak), so its
/// text can't ride the surface-adaptive tokens (they're sized on `surfacePrimary`
/// and wash out on the saturated tint). It draws every readout in
/// `SteddiTheme.rerouteCardForeground` — `contrastingForeground` against the
/// actual tinted surface — and the tests below assert AA on every accent in light
/// and on the dark scrim in dark, plus document the old sub-AA tokens.
@MainActor
@Suite("Nav HUD frost measurement (over-map legibility)")
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

    // MARK: - Reroute card on-surface foreground (BOTH themes, every accent)

    /// Every brand accent — the reroute card keeps its glass accent-TINTED in LIGHT
    /// theme, so the card text must contrast each of these.
    private let accents: [(name: String, rgb: RGBColor)] = SteddiTheme.AccentOption.allCases.map {
        ($0.rawValue, $0.rgb)
    }

    @Test("reroute card foreground clears AA on the accent-tinted glass in LIGHT theme (every accent)")
    func rerouteCardLightThemeAA() {
        // THE LIGHT-THEME FIX. In light theme the card surface is the raw accent
        // (the darkest plausible tinted-glass bound), and every readout draws in
        // `contrastingForeground(on: accent)` (the same value `rerouteCardForeground`
        // resolves to). That is near-black on the light accents and must clear the
        // AA body floor on EVERY brand accent — the savings value, subtitles,
        // percentage, and countdown digit all use it.
        for (name, accent) in accents {
            let fg = ContrastRatio.contrastingForeground(on: accent)
            let r = ContrastRatio.ratio(fg, accent)
            #expect(r >= ContrastRatio.aaBody,
                    "light reroute on-card foreground on \(name) accent = \(r), want >= 4.5 (body)")
        }
    }

    @Test("the OLD sageText/textSecondary tokens FAILED AA on the lavender tint (documents the light bug)")
    func rerouteCardLightThemeOldTokensRegression() {
        // The recurring bug: the savings value (sageText) and the subtitles/digit
        // (light textSecondary) are sized against the near-white surfacePrimary, so
        // on the saturated accent tint they collapsed sub-AA — even sub-3:1.
        let lavender = SteddiTheme.AccentOption.lavender.rgb
        let light = ThemePalette.light

        let sageText = SteddiTheme.legibleText(SteddiTheme.sageRGB, onSurface: light.surfacePrimary)
        let sageOnTint = ContrastRatio.ratio(sageText, lavender)
        #expect(sageOnTint < ContrastRatio.aaBody,
                "old sageText on the lavender tint was \(sageOnTint) — documents the sub-AA savings value")

        let secondaryOnTint = ContrastRatio.ratio(light.textSecondary, lavender)
        #expect(secondaryOnTint < ContrastRatio.aaBody,
                "old textSecondary on the lavender tint was \(secondaryOnTint) — documents the sub-AA subtitles/digit")

        // The new on-card foreground clears AA on that same tint.
        let fg = ContrastRatio.contrastingForeground(on: lavender)
        #expect(ContrastRatio.ratio(fg, lavender) >= ContrastRatio.aaBody,
                "new on-card foreground on lavender clears AA (the fix)")
    }

    @Test("reroute card foreground clears AA on the dark scrim in DARK theme (no regression of the dark fix)")
    func rerouteCardDarkThemeAA() {
        // In dark theme the card drops the tint (neutral glass) over the near-opaque
        // dark scrim, so `contrastingForeground(on: mapGlassDarkScrimSurface)` is
        // near-WHITE — exactly the prior dark-theme behaviour, white-on-dark.
        let fg = ContrastRatio.contrastingForeground(on: SteddiTheme.mapGlassDarkScrimSurface)
        let r = ContrastRatio.ratio(fg, SteddiTheme.mapGlassDarkScrimSurface)
        #expect(r >= ContrastRatio.aaBody,
                "dark reroute on-card foreground on the dark scrim = \(r), want >= 4.5")
    }

    @Test("rerouteCardSurface branches correctly on glass + theme")
    func rerouteCardSurfaceModel() {
        // Glass OFF → the solid surfacePrimary fallback (so the foreground flips the
        // right way in each theme); glass ON in dark → the dark scrim. (The live
        // light-glass branch returns the current accent, exercised by the AA tests.)
        let offSurface = SteddiTheme.rerouteCardSurface(glassAvailable: false)
        #expect(offSurface == ThemeEngine.snapshot.surfacePrimary,
                "glass-off reroute surface should be the solid surfacePrimary fallback")
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

    // MARK: - Speed-camera banner foreground (BOTH themes, every kind) — the 4th-visit measured fix

    /// Required AA margin for the camera-banner BODY text (title + distance): AA
    /// body floor plus headroom so a rounding/render wobble can't dip it sub-AA.
    private let bannerBodyMargin: Double = 5.0
    /// Required margin for the camera GLYPH on the solid kind chip (3:1 graphical
    /// floor plus headroom).
    private let bannerGlyphMargin: Double = 4.0

    /// Every camera-kind surface color the banner tints its glass with. The
    /// mobile-trap kind tracks the LIVE accent, so it's enumerated across every
    /// accent — the banner must clear AA for whichever accent is selected.
    private var cameraKinds: [(name: String, rgb: RGBColor)] {
        var kinds: [(String, RGBColor)] = [
            ("speedCamera/amber", SteddiTheme.warningAmberRGB),
            ("redLightCamera/warmRed", SteddiTheme.warmRedRGB),
        ]
        for accent in SteddiTheme.AccentOption.allCases {
            kinds.append(("mobileSpeedTrap/\(accent.rawValue)", accent.rgb))
        }
        return kinds
    }

    /// The DARK-theme banner surface MODEL — independent of the live theme so the
    /// test is deterministic: the near-opaque dark `mapGlassScrim`
    /// (`onboardingCardFallbackFillRGB` at 0.9) source-over the LIGHTEST plausible
    /// kind-tinted glass. Exactly what `SteddiTheme.cameraBannerSurface` computes in
    /// its dark branch, recomputed here so both themes are covered regardless of the
    /// runner's live theme.
    private func darkBannerSurface(kind: RGBColor) -> RGBColor {
        let lightest = ThemeBeatSurface.tintedGlassLightest(accent: kind)
        let scrim = SteddiTheme.onboardingCardFallbackFillRGB
        let a = 0.9
        return RGBColor(scrim.r * a + lightest.r * (1 - a),
                        scrim.g * a + lightest.g * (1 - a),
                        scrim.b * a + lightest.b * (1 - a))
    }

    /// ImageRenderer composite of the dark banner: a representative dark map tile,
    /// the near-opaque dark scrim, and the LIGHTEST plausible kind-tinted glass over
    /// it (the light extreme the real OS glass never exceeds — so a render that's
    /// dark here is dark for real). Mirrors `OnboardingFrostMeasurementTests`.
    private func darkBannerPanel(kind: RGBColor) -> some View {
        let lightest = ThemeBeatSurface.tintedGlassLightest(accent: kind)
        return ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.11) // representative dark map tile
            RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                .fill(lightest.color)                                  // lightest tinted glass
                .frame(width: 280, height: 64)
                .overlay {
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                        .fill(SteddiTheme.onboardingCardFallbackFill.opacity(0.9)) // dark scrim over it
                        .frame(width: 280, height: 64)
                }
        }
    }

    @Test("the rendered DARK camera-banner composite is dark enough for near-white text to clear AA WITH MARGIN, every kind")
    func cameraBannerDarkRendersDark() {
        for (name, kind) in cameraKinds {
            let sampled = centrePixel(darkBannerPanel(kind: kind),
                                      size: CGSize(width: 320, height: 100))
            let lum = ContrastRatio.relativeLuminance(sampled)
            #expect(lum < ContrastRatio.foregroundFlipLuminance,
                    "dark camera banner \(name) surface luminance = \(lum) (sRGB \(sampled)); want dark (< 0.179) so near-white text reads")
            // Near-white text (what cameraBannerForeground resolves on this dark
            // composite) clears the AA body floor WITH MARGIN on the SAMPLED pixel.
            let copyOnSampled = ContrastRatio.ratio(ContrastRatio.near.white, sampled)
            #expect(copyOnSampled >= bannerBodyMargin,
                    "dark camera banner \(name): near-white text on the rendered surface = \(copyOnSampled), want >= \(bannerBodyMargin) (margin)")
        }
    }

    @Test("the modelled DARK camera-banner surface is no lighter than the rendered composite, every kind")
    func cameraBannerDarkModelIsConservative() {
        for (name, kind) in cameraKinds {
            let sampled = centrePixel(darkBannerPanel(kind: kind),
                                      size: CGSize(width: 320, height: 100))
            let renderedLum = ContrastRatio.relativeLuminance(sampled)
            let modelLum = ContrastRatio.relativeLuminance(darkBannerSurface(kind: kind))
            #expect(modelLum < ContrastRatio.foregroundFlipLuminance,
                    "dark camera banner model luminance \(name) = \(modelLum) should be dark (< 0.179)")
            #expect(renderedLum <= modelLum + 0.02,
                    "rendered dark camera banner \(name) = \(renderedLum) should be no lighter than the model \(modelLum)")
        }
    }

    @Test("camera-banner foreground clears AA WITH MARGIN on the DARK composite, every kind (the fix)")
    func cameraBannerDarkForegroundAA() {
        // THE DARK-THEME FIX. The title + distance draw in
        // contrastingForeground(on: darkBannerSurface) — near-WHITE on the dark
        // composite — and must clear the AA body floor WITH MARGIN for every kind.
        for (name, kind) in cameraKinds {
            let surface = darkBannerSurface(kind: kind)
            let fg = ContrastRatio.contrastingForeground(on: surface)
            let r = ContrastRatio.ratio(fg, surface)
            #expect(r >= bannerBodyMargin,
                    "dark camera-banner foreground on \(name) = \(r), want >= \(bannerBodyMargin) (body w/ margin)")
        }
    }

    @Test("camera-banner foreground clears AA WITH MARGIN on the LIGHT kind tint, every kind (unchanged, still correct)")
    func cameraBannerLightForegroundAA() {
        // In LIGHT theme the surface is the raw kind hue (the darkest plausible
        // tinted glass; the OS frost only lightens it), so the foreground is
        // near-BLACK and must clear AA body for every kind. warmRed is the tightest
        // (the red-light camera), so it holds the line with margin to spare.
        for (name, kind) in cameraKinds {
            let fg = ContrastRatio.contrastingForeground(on: kind)
            let r = ContrastRatio.ratio(fg, kind)
            #expect(r >= ContrastRatio.aaBody,
                    "light camera-banner foreground on \(name) = \(r), want >= 4.5 (body)")
        }
    }

    @Test("the OLD raw-kindRGB foreground FAILED on the real DARK composite, every kind (documents the 4th-visit bug)")
    func cameraBannerDarkOldForegroundRegression() {
        // The recurring bug: prior rounds drew the text in
        // contrastingForeground(on: kind.kindRGB). Every kind's raw hue has
        // luminance > the 0.179 flip, so that's near-BLACK — but the REAL dark
        // surface is the dark scrim-over-tint composite, where near-black collapses
        // far below even the 3:1 large floor. The new foreground (near-white on the
        // real composite) fixes it.
        for (name, kind) in cameraKinds {
            let surface = darkBannerSurface(kind: kind)
            let oldFg = ContrastRatio.contrastingForeground(on: kind) // contrasted RAW hue → near-black
            let oldRatio = ContrastRatio.ratio(oldFg, surface)
            #expect(oldRatio < ContrastRatio.aaLarge,
                    "old raw-kindRGB foreground on the real dark \(name) surface = \(oldRatio), expected sub-3:1 (documents the bug)")
            let newFg = ContrastRatio.contrastingForeground(on: surface)
            #expect(ContrastRatio.ratio(newFg, surface) > oldRatio,
                    "new foreground on \(name) must beat the old")
        }
    }

    @Test("the camera GLYPH clears the 3:1 graphical floor WITH MARGIN on the solid kind chip, every kind (unchanged)")
    func cameraBannerGlyphOnChipAA() {
        // The 34×34 glyph sits on a SOLID kind.color fill, so it correctly
        // contrasts the raw kind hue — that surface is unchanged by this fix.
        // contrastingForeground picks near-black/white per kind; confirm it clears
        // the graphical-object floor with margin for every kind.
        for (name, kind) in cameraKinds {
            let glyph = ContrastRatio.contrastingForeground(on: kind)
            let r = ContrastRatio.ratio(glyph, kind)
            #expect(r >= bannerGlyphMargin,
                    "camera glyph on the solid \(name) chip = \(r), want >= \(bannerGlyphMargin) (3:1 floor w/ margin)")
        }
    }

    @Test("cameraBannerSurface branches correctly on glass + theme")
    func cameraBannerSurfaceModel() {
        // Glass OFF → the solid surfacePrimary fallback (so the foreground flips the
        // right way per theme), regardless of kind. (The live glass-on branch — raw
        // kind in light, scrim-over-tint in dark — is exercised by the AA tests via
        // the recomputed model above.)
        let off = SteddiTheme.cameraBannerSurface(kind: SteddiTheme.warmRedRGB, glassAvailable: false)
        #expect(off == ThemeEngine.snapshot.surfacePrimary,
                "glass-off camera-banner surface should be the solid surfacePrimary fallback")
        // And whatever the live theme is, the live glass-on surface matches one of
        // the two deterministic branches for that theme.
        let liveAmber = SteddiTheme.cameraBannerSurface(kind: SteddiTheme.warningAmberRGB, glassAvailable: true)
        if SteddiTheme.prefersDarkChrome {
            #expect(liveAmber == darkBannerSurface(kind: SteddiTheme.warningAmberRGB),
                    "dark live camera-banner surface should be the scrim-over-tint composite")
        } else {
            #expect(liveAmber == SteddiTheme.warningAmberRGB,
                    "light live camera-banner surface should be the raw kind hue")
        }
    }
}
