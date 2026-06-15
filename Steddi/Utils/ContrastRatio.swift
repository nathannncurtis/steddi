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
}
