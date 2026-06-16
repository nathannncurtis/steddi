import Testing
import Foundation
@testable import Steddi

/// Guards the foundational theme legibility fixes: every information-bearing
/// token pair must clear its WCAG floor against the *actual* palette surfaces.
/// These assertions are the regression seam for the accent-text and `textMuted`
/// contrast work — if a token or surface constant drifts, they fail loudly.
@Suite("Theme contrast (WCAG AA)")
struct ThemeContrastTests {

    // The three reference palettes the engine interpolates between.
    private let palettes: [(name: String, palette: ThemePalette)] = [
        ("dark", .dark), ("light", .light), ("grey", .grey),
    ]

    // MARK: - Sanity of the contrast helper itself

    @Test("Black on white is the canonical 21:1")
    func blackOnWhite() {
        let r = ContrastRatio.ratio(RGBColor(0, 0, 0), RGBColor(1, 1, 1))
        #expect(abs(r - 21.0) < 0.01)
    }

    @Test("Ratio is symmetric and identity is 1:1")
    func ratioInvariants() {
        let a = RGBColor(0.3, 0.5, 0.7), b = RGBColor(0.9, 0.9, 0.9)
        #expect(abs(ContrastRatio.ratio(a, b) - ContrastRatio.ratio(b, a)) < 1e-9)
        #expect(abs(ContrastRatio.ratio(a, a) - 1.0) < 1e-9)
    }

    @Test("darken/lighten move luminance the expected direction")
    func shiftDirection() {
        let c = RGBColor(0.6, 0.5, 0.4)
        #expect(ContrastRatio.relativeLuminance(ContrastRatio.darken(c, by: 0.4))
                < ContrastRatio.relativeLuminance(c))
        #expect(ContrastRatio.relativeLuminance(ContrastRatio.lighten(c, by: 0.4))
                > ContrastRatio.relativeLuminance(c))
    }

    // MARK: - textMuted (finding 3): AA for small label text

    @Test("textMuted clears AA on surfacePrimary in every palette")
    func textMutedPrimaryAA() {
        for (name, p) in palettes {
            let r = ContrastRatio.ratio(p.textMuted, p.surfacePrimary)
            #expect(r >= ContrastRatio.aaBody, "\(name) textMuted/primary = \(r), want >= 4.5")
        }
    }

    @Test("textMuted clears AA on surfaceSecondary in dark and light")
    func textMutedSecondaryAA() {
        // Grey is the palette ceiling: even pure white only reaches 4.26 on grey
        // elevated, so grey textMuted clears AA on primary and the 3:1 floor on
        // secondary/elevated — asserted separately below.
        for name in ["dark", "light"] {
            let p = name == "dark" ? ThemePalette.dark : .light
            let r = ContrastRatio.ratio(p.textMuted, p.surfaceSecondary)
            #expect(r >= ContrastRatio.aaBody, "\(name) textMuted/secondary = \(r), want >= 4.5")
        }
    }

    @Test("textMuted clears at least the 3:1 floor on every surface, every palette")
    func textMutedFloorEverywhere() {
        for (name, p) in palettes {
            for (sName, surf) in [("primary", p.surfacePrimary),
                                  ("secondary", p.surfaceSecondary),
                                  ("elevated", p.surfaceElevated)] {
                let r = ContrastRatio.ratio(p.textMuted, surf)
                #expect(r >= ContrastRatio.aaLarge, "\(name) textMuted/\(sName) = \(r), want >= 3.0")
            }
        }
    }

    @Test("textMuted is a strict improvement over the pre-fix values")
    func textMutedRegression() {
        // Pre-fix: dark 0.46, light 0.60, grey 0.65 — all failed AA on primary.
        let oldDark = ContrastRatio.ratio(RGBColor(0.46, 0.44, 0.42), ThemePalette.dark.surfacePrimary)
        let oldLight = ContrastRatio.ratio(RGBColor(0.60, 0.58, 0.56), ThemePalette.light.surfacePrimary)
        #expect(oldDark < ContrastRatio.aaBody)   // documents the bug
        #expect(oldLight < ContrastRatio.aaBody)
        #expect(ContrastRatio.ratio(ThemePalette.dark.textMuted, ThemePalette.dark.surfacePrimary) > oldDark)
        #expect(ContrastRatio.ratio(ThemePalette.light.textMuted, ThemePalette.light.surfacePrimary) > oldLight)
    }

    // MARK: - accent-as-text (finding 2): AA on primary/secondary, all accents

    @Test("text-safe accent clears AA on surfacePrimary for every accent in every palette")
    func accentTextPrimaryAA() {
        for option in SteddiTheme.AccentOption.allCases {
            for (name, p) in palettes {
                let safe = SteddiTheme.textSafeAccent(option.rgb, onSurface: p.surfacePrimary)
                let r = ContrastRatio.ratio(safe, p.surfacePrimary)
                #expect(r >= ContrastRatio.aaBody,
                        "\(name) accent(\(option.rawValue))/primary = \(r), want >= 4.5")
            }
        }
    }

    @Test("text-safe accent clears AA on surfaceSecondary for every accent in every palette")
    func accentTextSecondaryAA() {
        for option in SteddiTheme.AccentOption.allCases {
            for (name, p) in palettes {
                // The shift is sized against surfacePrimary; verify it carries to secondary.
                let safe = SteddiTheme.textSafeAccent(option.rgb, onSurface: p.surfacePrimary)
                let r = ContrastRatio.ratio(safe, p.surfaceSecondary)
                #expect(r >= ContrastRatio.aaBody,
                        "\(name) accent(\(option.rawValue))/secondary = \(r), want >= 4.5")
            }
        }
    }

    @Test("text-safe accent clears the 3:1 floor on surfaceElevated everywhere")
    func accentTextElevatedFloor() {
        for option in SteddiTheme.AccentOption.allCases {
            for (name, p) in palettes {
                let safe = SteddiTheme.textSafeAccent(option.rgb, onSurface: p.surfacePrimary)
                let r = ContrastRatio.ratio(safe, p.surfaceElevated)
                #expect(r >= ContrastRatio.aaLarge,
                        "\(name) accent(\(option.rawValue))/elevated = \(r), want >= 3.0")
            }
        }
    }

    @Test("raw brand accents failed AA on the light surface (documents the bug)")
    func rawAccentRegression() {
        for option in SteddiTheme.AccentOption.allCases {
            let raw = ContrastRatio.ratio(option.rgb, ThemePalette.light.surfacePrimary)
            #expect(raw < ContrastRatio.aaBody, "\(option.rawValue) raw was \(raw), expected sub-AA")
            let fixed = ContrastRatio.ratio(
                SteddiTheme.textSafeAccent(option.rgb, onSurface: ThemePalette.light.surfacePrimary),
                ThemePalette.light.surfacePrimary)
            #expect(fixed > raw)
        }
    }

    @Test("text-safe accent preserves hue ordering (a luminance shift, not a recolor)")
    func accentHuePreserved() {
        // The dominant channel of each brand hue stays dominant after the shift.
        for option in SteddiTheme.AccentOption.allCases {
            let base = option.rgb
            let safe = SteddiTheme.textSafeAccent(base, onSurface: ThemePalette.light.surfacePrimary)
            // Identify the max channel of the base and assert it is still >= the others.
            let baseMax = max(base.r, base.g, base.b)
            if baseMax == base.r { #expect(safe.r >= safe.g && safe.r >= safe.b) }
            else if baseMax == base.g { #expect(safe.g >= safe.r && safe.g >= safe.b) }
            else { #expect(safe.b >= safe.r && safe.b >= safe.g) }
        }
    }

    // MARK: - onAccent (foreground ON an accent FILL): white-on-fill was the bug

    @Test("onAccent clears AA on every accent FILL")
    func onAccentFillAA() {
        // The accent fill (`accentBrand`) is theme-independent — its luminance
        // alone decides the on-fill glyph color — so one assertion per accent
        // covers light/dark/grey/dynamic. Every current brand accent is light or
        // mid-tone, so onAccent resolves to near-black and clears AA.
        for option in SteddiTheme.AccentOption.allCases {
            let fg = ContrastRatio.contrastingForeground(on: option.rgb)
            let r = ContrastRatio.ratio(fg, option.rgb)
            #expect(r >= ContrastRatio.aaBody,
                    "onAccent(\(option.rawValue)) = \(r), want >= 4.5")
        }
    }

    @Test("the .steddiPrimary pairing (onAccent on accentBrand) clears AA on every accent")
    func steddiPrimaryButtonPairingAA() {
        // The canonical primary CTA `.buttonStyle(.steddiPrimary)` fills a Capsule
        // with `accentBrand` (the unshifted brand hue) and draws its label in
        // `onAccent` — the exact pairing this asserts. This is the contrast seam
        // for the app-wide CTA fix: if a future accent swatch or the `onAccent`
        // pairing drifts so the primary button's label/fill drops below AA, this
        // fails loudly (the bug it replaces, `.glassProminent.tint(accent)`'s
        // forced white label, fails AA on these accents — see
        // `whiteOnAccentRegression`).
        for option in SteddiTheme.AccentOption.allCases {
            // `onAccentRGB` is exactly what the `onAccent` SwiftUI color resolves
            // to over this fill; `accentBrand` is the literal capsule fill.
            let label = ContrastRatio.contrastingForeground(on: option.rgb) // == onAccentRGB for this fill
            let fill = option.rgb                                            // == accentBrand for this accent
            let r = ContrastRatio.ratio(label, fill)
            #expect(r >= ContrastRatio.aaBody,
                    ".steddiPrimary onAccent/accentBrand(\(option.rawValue)) = \(r), want >= 4.5")
        }
    }

    @Test("the .steddiPrimary Reduce-Transparency fallback (solid opaque accentBrand) clears AA on every accent")
    func steddiPrimaryReduceTransparencyFallbackAA() {
        // When glass is off (Reduce Transparency / Increase Contrast),
        // `.steddiPrimary` renders its `fallbackProminent` path: a FULLY OPAQUE
        // `accentBrand` capsule (no glass, no `navSurfaceOpacity(0.9)` reduction,
        // no hairline) drawn under the `onAccent` label. So the RT-state surface
        // is exactly `accentBrand` — identical to the glass-state pairing — and the
        // SAME `onAccent`/`accentBrand` contrast governs both states.
        //
        // This is the regression seam for the RT-fallback fix: it pins that the
        // CTA keeps its brand accent identity (the fill stays `accentBrand`, never
        // the old near-white `surfacePrimary` default) AND that the on-fill label
        // contrast is honest because the rendered surface is the opaque accent the
        // label color was computed for.
        for option in SteddiTheme.AccentOption.allCases {
            // Literal surface painted in the RT fallback = the opaque accentBrand.
            let rtFill = option.rgb
            // Literal label = onAccent (`contrastingForeground(on: accentBrand)`).
            let label = ContrastRatio.contrastingForeground(on: option.rgb)
            let r = ContrastRatio.ratio(label, rtFill)
            #expect(r >= ContrastRatio.aaBody,
                    ".steddiPrimary RT fallback onAccent/accentBrand(\(option.rawValue)) = \(r), want >= 4.5")
        }
    }

    @Test("the OLD translucent CTA fallback shifted the surface off accentBrand (documents the RT bug the prominent fill fixes)")
    func steddiPrimaryTranslucentFallbackRegression() {
        // The pre-fix fallback routed `.steddiPrimary` through the generic chrome
        // path: `fallbackFill.opacity(0.9)` composited over whatever sits behind
        // (the fixed-DARK onboarding backdrop), plus a hairline. The on-fill label
        // is computed for the OPAQUE accent, so it was painted on a surface that no
        // longer matched it. This documents that the rendered surface drifted off
        // `accentBrand`, and that the prominent (fully-opaque) fill removes the
        // drift entirely.
        let darkBackdrop = RGBColor(0, 0, 0) // onboarding beatBackground = .black
        let alpha = 0.9
        for option in SteddiTheme.AccentOption.allCases {
            let a = option.rgb
            // Source-over composite of accent@0.9 onto the dark backdrop.
            let composited = RGBColor(
                a.r * alpha + darkBackdrop.r * (1 - alpha),
                a.g * alpha + darkBackdrop.g * (1 - alpha),
                a.b * alpha + darkBackdrop.b * (1 - alpha)
            )
            // The composited surface is strictly darker than the opaque accent —
            // i.e. NOT the surface the `onAccent` label was sized for.
            #expect(ContrastRatio.relativeLuminance(composited)
                    < ContrastRatio.relativeLuminance(a),
                    "old fallback for \(option.rawValue) should have darkened the surface off accentBrand")
            // The prominent fix renders the opaque accent itself — zero drift.
            #expect(ContrastRatio.relativeLuminance(a)
                    == ContrastRatio.relativeLuminance(option.rgb))
        }
    }

    @Test("white-on-accent-fill failed AA (documents the bug onAccent fixes)")
    func whiteOnAccentRegression() {
        // Hardcoded `.white` glyphs on the accent fill — the pattern onAccent
        // replaces. Every brand accent is too light for white to clear AA.
        let white = RGBColor(1, 1, 1)
        for option in SteddiTheme.AccentOption.allCases {
            let raw = ContrastRatio.ratio(white, option.rgb)
            #expect(raw < ContrastRatio.aaBody,
                    "white/\(option.rawValue) was \(raw), expected sub-AA")
            let fixed = ContrastRatio.ratio(
                ContrastRatio.contrastingForeground(on: option.rgb), option.rgb)
            #expect(fixed > raw)
        }
    }

    @Test("contrastingForeground picks the higher-contrast endpoint")
    func contrastingForegroundPicksBest() {
        // On any fill, the chosen near-pure endpoint must out-contrast the other.
        let fills = [RGBColor(0.95, 0.95, 0.95), RGBColor(0.1, 0.1, 0.1),
                     RGBColor(0.5, 0.5, 0.5)] + SteddiTheme.AccentOption.allCases.map(\.rgb)
        for fill in fills {
            let chosen = ContrastRatio.contrastingForeground(on: fill)
            let other = chosen == ContrastRatio.near.black ? ContrastRatio.near.white
                                                           : ContrastRatio.near.black
            #expect(ContrastRatio.ratio(chosen, fill) >= ContrastRatio.ratio(other, fill),
                    "contrastingForeground picked the worse endpoint on \(fill)")
            // And the chosen endpoint clears the 3:1 badge/large-text floor.
            #expect(ContrastRatio.ratio(chosen, fill) >= ContrastRatio.aaLarge)
        }
    }

    @Test("contrastingForeground clears AA on every semantic FILL (badges)")
    func contrastingForegroundSemanticFillsAA() {
        let fills: [(String, RGBColor)] = [
            ("sage", SteddiTheme.sageRGB),
            ("amber", SteddiTheme.warningAmberRGB),
            ("warmRed", SteddiTheme.warmRedRGB),
        ]
        for (name, fill) in fills {
            let r = ContrastRatio.ratio(ContrastRatio.contrastingForeground(on: fill), fill)
            #expect(r >= ContrastRatio.aaBody, "onFill(\(name)) = \(r), want >= 4.5")
        }
    }

    // MARK: - Semantic TEXT variants (finding 3): legible on the surfaces

    private let semanticText: [(name: String, base: RGBColor)] = [
        ("sage", SteddiTheme.sageRGB),
        ("amber", SteddiTheme.warningAmberRGB),
        ("warmRed", SteddiTheme.warmRedRGB),
    ]

    @Test("semantic text variants clear AA on surfacePrimary in every palette")
    func semanticTextPrimaryAA() {
        for (sName, base) in semanticText {
            for (pName, p) in palettes {
                let safe = SteddiTheme.legibleText(base, onSurface: p.surfacePrimary)
                let r = ContrastRatio.ratio(safe, p.surfacePrimary)
                #expect(r >= ContrastRatio.aaBody,
                        "\(pName) \(sName)Text/primary = \(r), want >= 4.5")
            }
        }
    }

    @Test("semantic text variants clear AA on surfaceSecondary in dark and light")
    func semanticTextSecondaryAA() {
        // Grey is the palette ceiling (same envelope as textMuted/accent): a shift
        // sized on grey primary clears AA there but only the 3:1 floor on
        // secondary — asserted separately below.
        for (sName, base) in semanticText {
            for name in ["dark", "light"] {
                let p = name == "dark" ? ThemePalette.dark : .light
                let safe = SteddiTheme.legibleText(base, onSurface: p.surfacePrimary)
                let r = ContrastRatio.ratio(safe, p.surfaceSecondary)
                #expect(r >= ContrastRatio.aaBody,
                        "\(name) \(sName)Text/secondary = \(r), want >= 4.5")
            }
        }
    }

    @Test("semantic text variants clear at least 3:1 on every surface, every palette")
    func semanticTextFloorEverywhere() {
        for (sName, base) in semanticText {
            for (pName, p) in palettes {
                let safe = SteddiTheme.legibleText(base, onSurface: p.surfacePrimary)
                for (surfName, surf) in [("primary", p.surfacePrimary),
                                         ("secondary", p.surfaceSecondary),
                                         ("elevated", p.surfaceElevated)] {
                    let r = ContrastRatio.ratio(safe, surf)
                    #expect(r >= ContrastRatio.aaLarge,
                            "\(pName) \(sName)Text/\(surfName) = \(r), want >= 3.0")
                }
            }
        }
    }

    @Test("raw semantic hues failed AA as text on light/grey (documents the bug)")
    func semanticTextRegression() {
        // sage/amber/warmRed used raw as foreground text fail badly on the light
        // and grey surfaces — the bug legibleText fixes. (They're fine on dark.)
        for (sName, base) in semanticText {
            for name in ["light", "grey"] {
                let p = name == "light" ? ThemePalette.light : .grey
                let raw = ContrastRatio.ratio(base, p.surfacePrimary)
                #expect(raw < ContrastRatio.aaBody,
                        "\(name) raw \(sName) was \(raw), expected sub-AA")
                let fixed = ContrastRatio.ratio(
                    SteddiTheme.legibleText(base, onSurface: p.surfacePrimary), p.surfacePrimary)
                #expect(fixed > raw)
            }
        }
    }

    @Test("semantic text shift preserves hue ordering (luminance shift, not recolor)")
    func semanticTextHuePreserved() {
        for (_, base) in semanticText {
            for (_, p) in palettes {
                let safe = SteddiTheme.legibleText(base, onSurface: p.surfacePrimary)
                let baseMax = max(base.r, base.g, base.b)
                if baseMax == base.r { #expect(safe.r >= safe.g && safe.r >= safe.b) }
                else if baseMax == base.g { #expect(safe.g >= safe.r && safe.g >= safe.b) }
                else { #expect(safe.b >= safe.r && safe.b >= safe.g) }
            }
        }
    }

    // MARK: - Category label colors (finding 4)

    @Test("category labelColor clears AA on a 15%-tint-of-itself over the surface")
    func categoryLabelOnTintAA() {
        // LocationCardView renders the label in the category color on a
        // `themeColor.opacity(0.15)` capsule over the surface. Verify the legible
        // label clears AA against that composited tint, in light and dark.
        for category in PlaceCategory.allCases where category != .work && category != .other {
            for (pName, p) in [("light", ThemePalette.light), ("dark", ThemePalette.dark)] {
                // Composite 15% of the category hue over the surface (source-over).
                let a = 0.15
                let bg = RGBColor(
                    category.rgb.r * a + p.surfacePrimary.r * (1 - a),
                    category.rgb.g * a + p.surfacePrimary.g * (1 - a),
                    category.rgb.b * a + p.surfacePrimary.b * (1 - a))
                let label = SteddiTheme.legibleText(category.rgb, onSurface: p.surfacePrimary)
                let r = ContrastRatio.ratio(label, bg)
                #expect(r >= ContrastRatio.aaBody,
                        "\(pName) \(category.rawValue) label/tint = \(r), want >= 4.5")
            }
        }
    }

    // MARK: - Onboarding showcase/ask card (dark-scrim surface)

    /// The dark surface the showcase/ask beats' copy + glyphs sit on after the
    /// dark-card fix. `OnboardingShowcaseFrost.surface` is the conservative
    /// composite of the scrim painted in `OnboardingShowpieceCard`; every element
    /// is asserted against it. Pulling it once keeps these tests pinned to the
    /// same constant the views feed `legibleText`.
    private var onboardingFrost: RGBColor { OnboardingShowcaseFrost.surface }

    /// White at the opacity each onboarding copy tier uses, composited over a
    /// surface (the tokens are `Color.white.opacity(x)`, so the effective color
    /// drawn over the dark scrim is white blended toward the surface).
    private func whiteTier(_ opacity: Double, over surface: RGBColor) -> RGBColor {
        RGBColor(1 * opacity + surface.r * (1 - opacity),
                 1 * opacity + surface.g * (1 - opacity),
                 1 * opacity + surface.b * (1 - opacity))
    }

    @Test("onboarding frost surface is dark (white-on-dark, like the hero)")
    func onboardingFrostIsDark() {
        // The fix makes the card surface DARK so the fixed-white copy reads. The
        // constant must be below the WCAG black/white flip luminance, else the
        // whole premise (white copy + lightened glyphs) is wrong.
        let lum = ContrastRatio.relativeLuminance(onboardingFrost)
        #expect(lum < ContrastRatio.foregroundFlipLuminance,
                "onboarding frost luminance \(lum), want a dark surface (< 0.179)")
    }

    @Test("onboarding copy tiers clear their floors on the dark card surface")
    func onboardingCopyTiersAA() {
        // primary (white) and secondary (white .92) are body/interactive copy →
        // 4.5 floor; muted (white .66) is also used as body → 4.5 floor. All sit
        // on the dark scrim.
        let primary = ContrastRatio.ratio(whiteTier(1.0, over: onboardingFrost), onboardingFrost)
        let secondary = ContrastRatio.ratio(whiteTier(0.92, over: onboardingFrost), onboardingFrost)
        let muted = ContrastRatio.ratio(whiteTier(0.66, over: onboardingFrost), onboardingFrost)
        #expect(primary >= ContrastRatio.aaBody, "onboarding primary = \(primary), want >= 4.5")
        #expect(secondary >= ContrastRatio.aaBody, "onboarding secondary = \(secondary), want >= 4.5")
        #expect(muted >= ContrastRatio.aaBody, "onboarding muted = \(muted), want >= 4.5")
        // Tiers stay visually ranked.
        #expect(primary > secondary && secondary > muted)
    }

    @Test("onboarding showcase glyphAccent clears the 3:1 floor for every accent")
    func onboardingGlyphAccentFloor() {
        // The showcase glyphs (turn arrow, speedo sweep, no-go ring/nosign,
        // reroute line) and the permissions/emergency focal icons all draw in
        // `legibleText(accent, onSurface: frost)`. On the dark surface the shift
        // LIGHTENS the accent to the semantic target, clearing 3:1 with margin.
        for option in SteddiTheme.AccentOption.allCases {
            let glyph = SteddiTheme.legibleText(option.rgb, onSurface: onboardingFrost)
            let r = ContrastRatio.ratio(glyph, onboardingFrost)
            #expect(r >= ContrastRatio.aaLarge,
                    "glyphAccent(\(option.rawValue))/frost = \(r), want >= 3.0")
        }
    }

    @Test("onboarding focal-icon glyph clears the 3:1 floor (was raw accent ~1.1:1)")
    func onboardingFocalIconFloor() {
        // Permissions/Emergency 64pt focal icons now route through the same
        // glyphAccent as the showcase beats. Document that the RAW accent failed
        // on the old LIGHT frost, and that the lightened glyph clears 3:1 on the
        // dark surface.
        let oldLightFrost = RGBColor(0.73, 0.73, 0.75) // the measured ~0.73 frost
        for option in SteddiTheme.AccentOption.allCases {
            let rawOnOldFrost = ContrastRatio.ratio(option.rgb, oldLightFrost)
            #expect(rawOnOldFrost < ContrastRatio.aaLarge,
                    "raw \(option.rawValue) on old light frost was \(rawOnOldFrost), expected sub-3:1 (documents the bug)")
            let glyph = SteddiTheme.legibleText(option.rgb, onSurface: onboardingFrost)
            let fixed = ContrastRatio.ratio(glyph, onboardingFrost)
            #expect(fixed >= ContrastRatio.aaLarge,
                    "focal glyph(\(option.rawValue))/frost = \(fixed), want >= 3.0")
        }
    }

    @Test("onboarding no-go ring (glyphAccent @0.85 opacity) clears the 3:1 floor")
    func onboardingNoGoRingFloor() {
        // RouteRules draws the no-go ring as `glyphAccent.opacity(0.85)` over the
        // dark scrim. Composite the 0.85 glyph over the surface and assert 3:1.
        for option in SteddiTheme.AccentOption.allCases {
            let glyph = SteddiTheme.legibleText(option.rgb, onSurface: onboardingFrost)
            let a = 0.85
            let ring = RGBColor(glyph.r * a + onboardingFrost.r * (1 - a),
                                glyph.g * a + onboardingFrost.g * (1 - a),
                                glyph.b * a + onboardingFrost.b * (1 - a))
            let r = ContrastRatio.ratio(ring, onboardingFrost)
            #expect(r >= ContrastRatio.aaLarge,
                    "no-go ring(\(option.rawValue))/frost = \(r), want >= 3.0")
        }
    }

    @Test("onboarding decorative strokes (dashed reject, speedo track) clear the 3:1 floor")
    func onboardingDecorativeStrokesFloor() {
        // The route-rules dashed reject line is `onboardingTextMuted.opacity(0.6)`
        // (= white .66 * .6) and the speedo track is `.opacity(0.6)` too — both
        // meaning-light but should still clear the 3:1 graphical floor on the
        // dark scrim.
        let stroke = ContrastRatio.ratio(whiteTier(0.66 * 0.6, over: onboardingFrost), onboardingFrost)
        #expect(stroke >= ContrastRatio.aaLarge, "decorative stroke = \(stroke), want >= 3.0")
    }

    @Test("the OLD light-frost surface made white copy + glyphs fail (documents the root bug)")
    func onboardingLightFrostRegression() {
        // Before the dark-card fix, the card surface was the neutral .regular
        // glass the OS renders LIGHT (~0.73 sRGB), and the frost constant was a
        // guessed 0.62. Assert white copy and the glyph shift BOTH failed there,
        // and that the dark-card surface fixes both.
        let oldGuess = RGBColor(0.62, 0.62, 0.64)      // the pre-fix constant
        let oldRender = RGBColor(0.73, 0.73, 0.75)     // the measured real frost

        // White primary copy failed the AA-large floor on the real light frost.
        let whiteOnLight = ContrastRatio.ratio(RGBColor(1, 1, 1), oldRender)
        #expect(whiteOnLight < ContrastRatio.aaLarge,
                "white on the real light frost was \(whiteOnLight), expected sub-3:1")
        // It clears AA on the dark surface.
        let whiteOnDark = ContrastRatio.ratio(RGBColor(1, 1, 1), onboardingFrost)
        #expect(whiteOnDark >= ContrastRatio.aaBody)

        // The glyph shift against the old guessed surface failed 3:1 for the
        // worst accent; on the dark surface it clears 3:1, strictly better.
        for option in SteddiTheme.AccentOption.allCases {
            let onOldGuess = ContrastRatio.ratio(
                SteddiTheme.legibleText(option.rgb, onSurface: oldGuess), oldGuess)
            let onDark = ContrastRatio.ratio(
                SteddiTheme.legibleText(option.rgb, onSurface: onboardingFrost), onboardingFrost)
            #expect(onDark >= ContrastRatio.aaLarge)
            #expect(onDark > onOldGuess,
                    "\(option.rawValue): dark \(onDark) should beat old-guess \(onOldGuess)")
        }
    }

    // MARK: - Trend insight magnitude badge (sage/warmRed text on 15% tint)

    @Test("trend magnitude badge text clears its floor on a 15%-tint-of-itself over the card")
    func trendBadgeOnTintAA() {
        // TrendInsightCard.magnitudeBadge renders the value (+/-N min) in the
        // legible semantic text variant on a `sentimentColor.opacity(0.15)`
        // capsule over the card's surfaceSecondary. The legible shift is sized
        // against surfacePrimary, so over the (slightly different) surface
        // Secondary the composited badge clears the 3:1 large/non-body floor in
        // every palette and stays a large improvement over the raw sage/warmRed
        // it replaced (which were ~1.8–2.4:1 and failed even that). Mirrors
        // `semanticTextFloorEverywhere`'s 3:1 floor on the non-primary surfaces.
        let badges: [(String, RGBColor)] = [
            ("better/sage", SteddiTheme.sageRGB),
            ("worse/warmRed", SteddiTheme.warmRedRGB),
        ]
        for (name, base) in badges {
            for (pName, p) in palettes {
                let a = 0.15
                let bg = RGBColor(
                    base.r * a + p.surfaceSecondary.r * (1 - a),
                    base.g * a + p.surfaceSecondary.g * (1 - a),
                    base.b * a + p.surfaceSecondary.b * (1 - a))
                let label = SteddiTheme.legibleText(base, onSurface: p.surfacePrimary)
                let r = ContrastRatio.ratio(label, bg)
                #expect(r >= ContrastRatio.aaLarge,
                        "\(pName) \(name) badge/tint = \(r), want >= 3.0")
                // And a strict improvement over the raw hue it replaced.
                let raw = ContrastRatio.ratio(base, bg)
                #expect(r > raw,
                        "\(pName) \(name) legible \(r) should beat raw \(raw)")
            }
        }
    }

    // MARK: - Onboarding THEME beat (accent-tinted card OR dark fallback)

    /// The theme beat is the one showcase beat that keeps its glass ACCENT-TINTED
    /// (the delight peak), so it's exempt from the dark scrim the other beats use.
    /// Its copy/labels/descriptions/chip therefore can't assume a dark card: each
    /// resolves its color from `contrastingForeground` against the ACTUAL surface
    /// it sits on (`ThemeBeatSurface`), so it reads near-black on light accents and
    /// near-white on dark.
    ///
    /// CRITICAL — the card has TWO surfaces, and the model BRANCHES on glass
    /// availability:
    ///   - glass AVAILABLE → the bright accent-tinted glass (copy near-black).
    ///   - glass UNAVAILABLE (Reduce Transparency / Increase Contrast) →
    ///     `steddiGlass` discards the accent and paints the solid DARK
    ///     `onboardingCardFallbackFill`, so the copy must flip to near-WHITE. A
    ///     prior fix only contrasted against the accent surface, so under Reduce
    ///     Transparency the copy resolved near-black on the near-black fallback —
    ///     invisible for EVERY accent. These tests measure the contrast for every
    ///     accent in BOTH states; the fallback state is the one that was broken,
    ///     so it is covered explicitly.

    /// Both glass states, as the view's surface model sees them. The theme beat now
    /// carries a partial dark scrim in BOTH (scrim-over-tinted-glass when glass is
    /// on, the solid dark fallback when it's off), so the copy is near-white either
    /// way and clears AA with margin.
    private let glassStates: [(name: String, available: Bool)] = [
        ("glass-available (partial scrim over accent tint)", true),
        ("glass-unavailable (Reduce Transparency / dark fallback)", false),
    ]

    /// The theme-beat body-copy bar is the WCAG AA body floor (4.5) PLUS margin —
    /// the recurring bug was copy landing AT/below 4.5 on the real (darker than
    /// modelled) tinted glass, so we require headroom, not a floor-hugging pass.
    private let aaBodyMargin: Double = 5.0

    @Test("theme-beat shell copy clears AA WITH MARGIN on the card for every accent, in BOTH glass states")
    func onboardingThemeShellCopyAA() {
        // Header glyph + title + both section titles/subtitles sit directly on the
        // card shell — now the partial dark scrim over the tinted glass (glass on)
        // or the solid dark fallback (glass off). Near-white copy on both; must
        // clear the 5:1 margin bar, not just the 4.5 floor (the old bare-tint card
        // sat AT/below 4.5 — the bug this ends).
        for (sName, glass) in glassStates {
            for option in SteddiTheme.AccentOption.allCases {
                let surface = ThemeBeatSurface.cardShell(accent: option.rgb, glassAvailable: glass)
                let fg = ContrastRatio.contrastingForeground(on: surface)
                let r = ContrastRatio.ratio(fg, surface)
                #expect(r >= aaBodyMargin,
                        "theme shell copy(\(option.rawValue), \(sName)) = \(r), want >= 5.0 (margin)")
            }
        }
    }

    @Test("theme-card label + description clear AA WITH MARGIN on every card's own surface, selected/deselected, BOTH glass states")
    func onboardingThemeCardCopyAA() {
        // Each theme-selection row draws a small white wash over the effective
        // (scrimmed, dark) shell. The label/description must contrast with THAT
        // composite. The wash opacities (0.12 selected / 0.05 deselected) are tuned
        // so even the lightened selected row stays dark enough for near-white copy
        // to clear the 5:1 margin bar on every accent in both states.
        for (sName, glass) in glassStates {
            for option in SteddiTheme.AccentOption.allCases {
                for selected in [true, false] {
                    let surface = ThemeBeatSurface.themeCard(
                        accent: option.rgb, selected: selected, glassAvailable: glass)
                    let fg = ContrastRatio.contrastingForeground(on: surface)
                    let r = ContrastRatio.ratio(fg, surface)
                    #expect(r >= aaBodyMargin,
                            "theme card copy(\(option.rawValue), selected=\(selected), \(sName)) = \(r), want >= 5.0 (margin)")
                }
            }
        }
    }

    @Test("theme-card deselected icon (rowForeground @0.7) clears the 3:1 glyph floor for every accent, BOTH glass states")
    func onboardingThemeDeselectedIconFloor() {
        // The deselected card icon is the row foreground at 0.7 opacity (a glyph →
        // 3:1 floor). Composite it over the deselected card surface and assert in
        // both states.
        for (sName, glass) in glassStates {
            for option in SteddiTheme.AccentOption.allCases {
                let surface = ThemeBeatSurface.themeCard(
                    accent: option.rgb, selected: false, glassAvailable: glass)
                let fg = ContrastRatio.contrastingForeground(on: surface)
                let a = 0.7
                let icon = RGBColor(fg.r * a + surface.r * (1 - a),
                                    fg.g * a + surface.g * (1 - a),
                                    fg.b * a + surface.b * (1 - a))
                let r = ContrastRatio.ratio(icon, surface)
                #expect(r >= ContrastRatio.aaLarge,
                        "theme deselected icon(\(option.rawValue), \(sName)) = \(r), want >= 3.0")
            }
        }
    }

    @Test("theme-card selected border (rowForeground @0.8) clears the 3:1 floor for every accent, BOTH glass states")
    func onboardingThemeSelectedBorderFloor() {
        // The selected card border is the row foreground at 0.8 opacity (a non-text
        // affordance → 3:1 floor) over the selected card surface, in both states.
        for (sName, glass) in glassStates {
            for option in SteddiTheme.AccentOption.allCases {
                let surface = ThemeBeatSurface.themeCard(
                    accent: option.rgb, selected: true, glassAvailable: glass)
                let fg = ContrastRatio.contrastingForeground(on: surface)
                let a = 0.8
                let border = RGBColor(fg.r * a + surface.r * (1 - a),
                                      fg.g * a + surface.g * (1 - a),
                                      fg.b * a + surface.b * (1 - a))
                let r = ContrastRatio.ratio(border, surface)
                #expect(r >= ContrastRatio.aaLarge,
                        "theme selected border(\(option.rawValue), \(sName)) = \(r), want >= 3.0")
            }
        }
    }

    @Test("'Recommended' chip clears AA on a self-contained contrasting capsule for every accent, BOTH glass states")
    func onboardingRecommendedChipAA() {
        // The chip's capsule is filled with the contrasting tone for the card
        // surface, and its text with the contrasting tone for THAT fill — a fixed
        // black/white pairing, accent- and glass-state-independent (~17:1).
        for (sName, glass) in glassStates {
            for option in SteddiTheme.AccentOption.allCases {
                let surface = ThemeBeatSurface.themeCard(
                    accent: option.rgb, selected: true, glassAvailable: glass)
                let capsuleFill = ContrastRatio.contrastingForeground(on: surface)
                let text = ContrastRatio.contrastingForeground(on: capsuleFill)
                let r = ContrastRatio.ratio(text, capsuleFill)
                #expect(r >= ContrastRatio.aaBody,
                        "Recommended chip(\(option.rawValue), \(sName)) = \(r), want >= 4.5")
            }
        }
    }

    @Test("selected-accent swatch ring clears the 3:1 graphical floor on the card for every accent, BOTH glass states")
    func onboardingThemeSelectedRingFloor() {
        // The selected-swatch ring's primary stroke is the card's contrasting
        // foreground (near-black on the light accent card, near-white on the dark
        // fallback) — `selectionRing` in the view. A fixed-white ring fell to
        // ~1.6–2.2:1 on the light accents (the bug, comment "White reads on any
        // accent" was wrong); a fixed-dark ring would vanish on the dark fallback.
        // The contrast-anchored ring clears the 3:1 graphical floor on BOTH
        // surfaces for every accent.
        for (sName, glass) in glassStates {
            for option in SteddiTheme.AccentOption.allCases {
                let surface = ThemeBeatSurface.cardShell(accent: option.rgb, glassAvailable: glass)
                let ring = ContrastRatio.contrastingForeground(on: surface)
                let r = ContrastRatio.ratio(ring, surface)
                #expect(r >= ContrastRatio.aaLarge,
                        "swatch selected ring(\(option.rawValue), \(sName)) = \(r), want >= 3.0")
            }
        }
    }

    @Test("swatch hairline (option.contrastingGlyph @0.75) clears the 3:1 floor against the swatch fill for every accent")
    func onboardingThemeSwatchHairlineFloor() {
        // The swatch hairline bounds the circle against the card; it's drawn in the
        // swatch's OWN contrasting glyph at 0.75 opacity over the swatch fill, so it
        // gives every swatch a crisp edge (the SELECTED swatch's fill equals the
        // card tint, so a white hairline ~1.3–2.0:1 dissolved). The glyph contrasts
        // the fill 5–8:1; at 0.75 over the fill it clears the 3:1 graphical floor
        // (worst slate 3.70:1).
        for option in SteddiTheme.AccentOption.allCases {
            let fill = option.rgb
            // `contrastingGlyph` is the near-black/white glyph for this accent;
            // `contrastingForeground` resolves the same near-pure endpoint.
            let glyph = ContrastRatio.contrastingForeground(on: fill)
            let a = 0.75
            let hairline = RGBColor(glyph.r * a + fill.r * (1 - a),
                                    glyph.g * a + fill.g * (1 - a),
                                    glyph.b * a + fill.b * (1 - a))
            let r = ContrastRatio.ratio(hairline, fill)
            #expect(r >= ContrastRatio.aaLarge,
                    "swatch hairline(\(option.rawValue)) = \(r), want >= 3.0")
        }
    }

    /// The REAL accent-tinted glass composite over the dark cinematic backdrop, as
    /// measured on device (~accent at ~0.82 tint opacity over near-black) — DARKER
    /// than the raw accent the old model assumed. This is the surface the old near-
    /// black copy actually landed on.
    private func realTintedGlass(_ accent: RGBColor) -> RGBColor {
        let alpha = 0.82
        return RGBColor(accent.r * alpha, accent.g * alpha, accent.b * alpha)
    }

    @Test("the OLD raw-accent model under-predicted real tinted-glass darkness — copy landed AT/below the AA floor (documents the bug)")
    func onboardingThemeRegression() {
        // --- Glass-ON regression (THIS fix): the under-predicted tinted-glass darkness. ---
        // The OLD model treated the glass-on surface as the RAW accent (L > flip for
        // every accent), so `contrastingForeground` picked NEAR-BLACK copy. But the
        // REAL tinted glass composites DARKER over the dark backdrop, so that near-
        // black copy landed at only ~4.2–4.5:1 on the default lavender (AT/below the
        // 4.5 AA floor) and below it on the darker accents — with NO 5:1 margin. The
        // partial dark scrim flips the surface to reliably dark, the copy to near-
        // white, and the contrast to ≥5:1 with margin.
        // The darker-tinting accents — every accent EXCEPT gold (gold is the
        // lightest swatch, the one that always read fine ~5–6:1). These are the
        // accents whose real tinted glass falls into the worst luminance band.
        let darkerAccents: [SteddiTheme.AccentOption] = [.lavender, .ocean, .sage, .coral, .slate]
        for option in SteddiTheme.AccentOption.allCases {
            // OLD: near-black copy (chosen against the raw accent) measured on the
            // REAL (darker) tinted glass — for the darker accents this gave NO 5:1
            // margin (the bug); only gold cleared it.
            let oldFg = ContrastRatio.contrastingForeground(on: option.rgb) // near-black
            let oldR = ContrastRatio.ratio(oldFg, realTintedGlass(option.rgb))
            if darkerAccents.contains(option) {
                #expect(oldR < aaBodyMargin,
                        "old near-black copy(\(option.rawValue)) on the REAL tinted glass was \(oldR), expected < 5.0 (no margin — the bug)")
            }
            // NEW: near-white copy on the partial-scrim (dark) shell, with margin,
            // for EVERY accent.
            let newShell = ThemeBeatSurface.cardShell(accent: option.rgb, glassAvailable: true)
            let newR = ContrastRatio.ratio(ContrastRatio.contrastingForeground(on: newShell), newShell)
            #expect(newR >= aaBodyMargin,
                    "new theme copy(\(option.rawValue)) on the scrimmed shell = \(newR), want >= 5.0 (margin)")
            #expect(newR > oldR)
        }
        // The DEFAULT lavender is the canary — confirm the old near-black copy sat
        // right at/under the bare AA floor on the real tinted glass.
        let lavender = SteddiTheme.AccentOption.lavender.rgb
        let lavOldR = ContrastRatio.ratio(
            ContrastRatio.contrastingForeground(on: lavender), realTintedGlass(lavender))
        #expect(lavOldR < ContrastRatio.aaBody + 0.3,
                "default lavender old near-black copy on real tinted glass was \(lavOldR) — at/under the AA floor (the canary)")

        // --- Glass-OFF regression (the prior Reduce-Transparency fix, still guarded). ---
        // The prior fix contrasted ALL theme-beat copy against the ACCENT surface
        // even when glass was off; under Reduce Transparency the card is the dark
        // `onboardingCardFallbackFill`, so that near-black copy landed near-black-
        // on-near-black — invisible for EVERY accent. Document that the OLD choice
        // (contrastingForeground against the ACCENT) fails on the dark fallback,
        // and the NEW choice (against the fallback surface) clears AA, for every
        // accent and both the shell and the row surfaces.
        for option in SteddiTheme.AccentOption.allCases {
            let darkShell = ThemeBeatSurface.cardShell(accent: option.rgb, glassAvailable: false)
            // OLD: copy color was resolved against the bright accent (near-black)
            // but actually painted on the dark fallback shell.
            let oldFg = ContrastRatio.contrastingForeground(on: option.rgb)
            let oldR = ContrastRatio.ratio(oldFg, darkShell)
            #expect(oldR < ContrastRatio.aaLarge,
                    "old theme copy(\(option.rawValue)) on dark fallback was \(oldR), expected sub-3:1 (the Reduce-Transparency bug)")
            // NEW: copy color resolved against the actual (dark fallback) surface.
            let newFg = ContrastRatio.contrastingForeground(on: darkShell)
            let newR = ContrastRatio.ratio(newFg, darkShell)
            #expect(newR >= aaBodyMargin,
                    "new theme copy(\(option.rawValue)) on dark fallback = \(newR), want >= 5.0 (margin)")
            #expect(newR > oldR)

            // Same for the worst row (selected 'Light' description). The OLD bug
            // resolved the row foreground against the RAW accent (near-black) and
            // painted it on the dark fallback row — invisible.
            let darkRow = ThemeBeatSurface.themeCard(accent: option.rgb, selected: true, glassAvailable: false)
            let oldRowFg = ContrastRatio.contrastingForeground(on: option.rgb) // near-black (raw accent)
            let oldRowR = ContrastRatio.ratio(oldRowFg, darkRow)
            #expect(oldRowR < ContrastRatio.aaLarge,
                    "old theme row(\(option.rawValue)) on dark fallback was \(oldRowR), expected sub-3:1")
            let newRowR = ContrastRatio.ratio(ContrastRatio.contrastingForeground(on: darkRow), darkRow)
            #expect(newRowR >= aaBodyMargin)
            #expect(newRowR > oldRowR)
        }
    }
}
