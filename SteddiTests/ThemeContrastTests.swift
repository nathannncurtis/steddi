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
}
