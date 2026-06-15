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
}
