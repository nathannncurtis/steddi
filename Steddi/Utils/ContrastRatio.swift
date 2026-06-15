import Foundation

/// WCAG 2.x relative-luminance / contrast-ratio math over `RGBColor`.
///
/// Kept UIKit-free and pure so the foundational theme tokens (accent text,
/// `textMuted`) can be asserted against the actual surface colors in unit tests.
/// All inputs are treated as straight sRGB in 0…1, matching how the palette and
/// accent constants are authored in `ThemePalette` / `SteddiTheme`.
enum ContrastRatio {

    /// WCAG AA floor for normal-size body text.
    static let aaBody: Double = 4.5
    /// WCAG AA floor for large/bold text and non-text UI components.
    static let aaLarge: Double = 3.0

    /// sRGB gamma → linear, per WCAG.
    static func linearize(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance of a straight-sRGB color.
    static func relativeLuminance(_ c: RGBColor) -> Double {
        0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b)
    }

    /// WCAG contrast ratio between two colors (always >= 1, order-independent).
    static func ratio(_ a: RGBColor, _ b: RGBColor) -> Double {
        let l1 = relativeLuminance(a)
        let l2 = relativeLuminance(b)
        let hi = max(l1, l2)
        let lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    // MARK: - Color transforms used to derive text-safe accent variants

    /// Multiply toward black. `f` in 0…1; 0 leaves the color, 1 yields black.
    static func darken(_ c: RGBColor, by f: Double) -> RGBColor {
        let f = min(1, max(0, f))
        return RGBColor(c.r * (1 - f), c.g * (1 - f), c.b * (1 - f))
    }

    /// Mix toward white. `f` in 0…1; 0 leaves the color, 1 yields white.
    static func lighten(_ c: RGBColor, by f: Double) -> RGBColor {
        let f = min(1, max(0, f))
        return RGBColor(c.r + (1 - c.r) * f, c.g + (1 - c.g) * f, c.b + (1 - c.b) * f)
    }

    // MARK: - Contrasting foreground (black vs white on an arbitrary fill)

    /// The luminance at which black and white contrast equally against a fill,
    /// per WCAG: `sqrt(1.05 * 0.05) - 0.05 ≈ 0.179`. Fills brighter than this
    /// pair better with black text; darker fills pair with white.
    static let foregroundFlipLuminance: Double = 0.17912878474779

    /// Pick black or white for maximum legibility on `fill`, by WCAG luminance.
    /// Returns whichever gives the higher contrast ratio — the canonical
    /// "on-color" choice for text/glyphs that sit *on* a solid fill.
    ///
    /// Both endpoints are near-pure (`black`/`white` tints below) rather than
    /// `0`/`1`: a hair of the surface tone reads softer than dead black/white
    /// while still clearing AA on every Steddi fill (the closest call, white on a
    /// dark fill, still lands ≥4.5:1; black on the lightest brand fill ≥5:1).
    static func contrastingForeground(on fill: RGBColor) -> RGBColor {
        relativeLuminance(fill) > foregroundFlipLuminance ? near.black : near.white
    }

    /// Near-pure endpoints used by `contrastingForeground`. Off-pure so on-fill
    /// text doesn't glare, matched to Steddi's warm dark / warm white surfaces.
    enum near {
        static let black = RGBColor(0.09, 0.08, 0.07)
        static let white = RGBColor(0.98, 0.97, 0.96)
    }

    // MARK: - Surface-adaptive legible shift (shared by accent + semantic text)

    /// Shift a brand/semantic color toward black or white — whichever direction
    /// the `surface` has headroom in — by the minimal amount that reaches
    /// `target` contrast, clamped to `cap`. Hue is preserved (a pure luminance
    /// shift via `darken`/`lighten`), so the color still reads as itself.
    ///
    /// This is the generalisation of the accent text-safe math: light surfaces
    /// darken the color, dark/mid surfaces lighten it. Semantic *text* tokens
    /// (`sageText`, `amberText`, traffic-status text) call this against the live
    /// surface so a value rendered in sage/amber stays legible in every theme,
    /// where the raw hue fails AA on light/grey (sage 2.30:1, amber 1.92:1 on
    /// light primary). Mid-tone (grey) surfaces lack the headroom to reach a high
    /// target even at the cap; the result then lands at the best the palette
    /// allows, matching the envelope of `textPrimary`/`accent` in grey.
    static func legible(
        _ base: RGBColor,
        onSurface surface: RGBColor,
        target: Double,
        cap: Double = 0.85
    ) -> RGBColor {
        let towardWhite = relativeLuminance(surface) < 0.5
        let shift: (Double) -> RGBColor = { f in
            towardWhite ? lighten(base, by: f) : darken(base, by: f)
        }
        // If even the cap can't reach the target (mid-tone surface), take the cap.
        guard ratio(shift(cap), surface) >= target else { return shift(cap) }
        var lo = 0.0, hi = cap
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if ratio(shift(mid), surface) >= target { hi = mid } else { lo = mid }
        }
        return shift(hi)
    }
}
