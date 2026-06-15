import SwiftUI

/// Plain RGB triple used for all theme interpolation math.
/// Kept UIKit-free so blending is unit-testable and allocation-free.
struct RGBColor: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    var color: Color { Color(red: r, green: g, blue: b) }
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    /// Linear interpolation, component-wise. `t` is clamped to 0...1.
    static func lerp(_ a: RGBColor, _ b: RGBColor, _ t: Double) -> RGBColor {
        let t = min(1, max(0, t))
        return RGBColor(
            a.r + (b.r - a.r) * t,
            a.g + (b.g - a.g) * t,
            a.b + (b.b - a.b) * t
        )
    }

    /// Additive offset (warmth tinting), clamped to the displayable range.
    func offset(by vector: SIMD3<Float>) -> RGBColor {
        RGBColor(
            min(1, max(0, r + Double(vector.x))),
            min(1, max(0, g + Double(vector.y))),
            min(1, max(0, b + Double(vector.z)))
        )
    }

    /// Relative luminance (Rec. 709 weights) — used to pick dark vs light
    /// system chrome for an interpolated surface.
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// One of the three reference palettes the engine interpolates between.
/// Values mirror the historical SteddiTheme adaptive colors exactly, so a
/// fully-dark or fully-light ThemeState is pixel-identical to the old theme.
struct ThemePalette: Equatable {
    var surfacePrimary: RGBColor
    var surfaceSecondary: RGBColor
    var surfaceElevated: RGBColor
    var textPrimary: RGBColor
    var textSecondary: RGBColor
    var textMuted: RGBColor

    /// Warm dark — matches the pre-dynamic dark trait colors.
    /// `textMuted` brightened from 0.46→0.65 so it clears WCAG AA (4.5:1) for
    /// small label text on every dark surface (6.99/5.82/4.86 on P/S/E); the old
    /// value sat at 3.57/2.97/2.48 and failed AA on the information-bearing labels
    /// that read it (follow-on maneuver, trip summary). Warm cast preserved.
    static let dark = ThemePalette(
        surfacePrimary: RGBColor(0.11, 0.10, 0.09),
        surfaceSecondary: RGBColor(0.17, 0.16, 0.15),
        surfaceElevated: RGBColor(0.22, 0.21, 0.19),
        textPrimary: RGBColor(0.97, 0.96, 0.95),
        textSecondary: RGBColor(0.66, 0.63, 0.60),
        textMuted: RGBColor(0.66, 0.64, 0.62)
    )

    /// Neutral graphite — the grey-mode milestone between dark and light.
    /// Deliberately desaturated (no warm cast) so it reads as "grey", with
    /// light text for contrast against the mid surfaces.
    /// `textMuted` lightened from 0.65→0.88 toward the grey ceiling. The grey
    /// mid-tone surfaces have very little contrast headroom — even pure white
    /// only reaches 4.26:1 on the elevated surface — so this is the best
    /// achievable: 5.09/4.04/3.24 on P/S/E (was 2.75/2.18/1.75, well below any
    /// floor). Primary clears AA; secondary/elevated clear the 3:1 large-text/UI
    /// floor, matching the contrast envelope of `textPrimary` itself in grey mode.
    static let grey = ThemePalette(
        surfacePrimary: RGBColor(0.36, 0.36, 0.37),
        surfaceSecondary: RGBColor(0.42, 0.42, 0.43),
        surfaceElevated: RGBColor(0.48, 0.48, 0.49),
        textPrimary: RGBColor(0.96, 0.96, 0.96),
        textSecondary: RGBColor(0.80, 0.80, 0.81),
        textMuted: RGBColor(0.88, 0.88, 0.89)
    )

    /// Warm white — matches the pre-dynamic light trait colors.
    /// `textMuted` darkened from 0.60→0.40 so it clears WCAG AA (4.5:1) for small
    /// label text on every light surface (5.57/5.09/4.64 on P/S/E); the old value
    /// sat at 2.83/2.58/2.35 and failed even the 3:1 floor. Warm cast preserved.
    static let light = ThemePalette(
        surfacePrimary: RGBColor(0.98, 0.97, 0.96),
        surfaceSecondary: RGBColor(0.94, 0.93, 0.92),
        surfaceElevated: RGBColor(0.90, 0.89, 0.88),
        textPrimary: RGBColor(0.11, 0.10, 0.09),
        textSecondary: RGBColor(0.45, 0.43, 0.41),
        textMuted: RGBColor(0.40, 0.39, 0.38)
    )

    /// Component-wise linear interpolation between two palettes.
    static func lerp(_ a: ThemePalette, _ b: ThemePalette, _ t: Double) -> ThemePalette {
        ThemePalette(
            surfacePrimary: RGBColor.lerp(a.surfacePrimary, b.surfacePrimary, t),
            surfaceSecondary: RGBColor.lerp(a.surfaceSecondary, b.surfaceSecondary, t),
            surfaceElevated: RGBColor.lerp(a.surfaceElevated, b.surfaceElevated, t),
            textPrimary: RGBColor.lerp(a.textPrimary, b.textPrimary, t),
            textSecondary: RGBColor.lerp(a.textSecondary, b.textSecondary, t),
            textMuted: RGBColor.lerp(a.textMuted, b.textMuted, t)
        )
    }

    /// Blend across the full dark→light axis.
    ///
    /// - progress 0 is fully dark, 1 fully light.
    /// - `throughGrey` routes the midpoint through the grey palette
    ///   (0.5 == exactly grey); otherwise dark blends straight into light.
    static func blend(
        dark: ThemePalette = .dark,
        grey: ThemePalette = .grey,
        light: ThemePalette = .light,
        progress: Double,
        throughGrey: Bool
    ) -> ThemePalette {
        let p = min(1, max(0, progress))
        guard throughGrey else { return lerp(dark, light, p) }
        if p < 0.5 {
            return lerp(dark, grey, p * 2)
        }
        return lerp(grey, light, (p - 0.5) * 2)
    }
}
