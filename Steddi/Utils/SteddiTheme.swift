import SwiftUI
import CoreLocation
import MapKit

/// Steddi's visual identity — warm, steady, confident.
enum SteddiTheme {

    // MARK: - Accent Color Options

    enum AccentOption: String, CaseIterable {
        case lavender, ocean, sage, coral, gold, slate

        /// Raw brand hue. Single source of truth for `color`/`uiColor` and the
        /// contrast math, so the text-safe shift can't drift from the swatch.
        var rgb: RGBColor {
            switch self {
            case .lavender: return RGBColor(0.61, 0.56, 0.77)  // #9B8EC4
            case .ocean:    return RGBColor(0.29, 0.56, 0.85)  // #4A90D9
            case .sage:     return RGBColor(0.42, 0.61, 0.49)  // #6B9B7D
            case .coral:    return RGBColor(0.83, 0.45, 0.42)  // #D4726A
            case .gold:     return RGBColor(0.77, 0.64, 0.31)  // #C4A44E
            case .slate:    return RGBColor(0.48, 0.55, 0.60)  // #7A8B9A
            }
        }

        var color: Color { rgb.color }

        var uiColor: UIColor {
            switch self {
            case .lavender: return UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 1.0)
            case .ocean:    return UIColor(red: 0.29, green: 0.56, blue: 0.85, alpha: 1.0)
            case .sage:     return UIColor(red: 0.42, green: 0.61, blue: 0.49, alpha: 1.0)
            case .coral:    return UIColor(red: 0.83, green: 0.45, blue: 0.42, alpha: 1.0)
            case .gold:     return UIColor(red: 0.77, green: 0.64, blue: 0.31, alpha: 1.0)
            case .slate:    return UIColor(red: 0.48, green: 0.55, blue: 0.60, alpha: 1.0)
            }
        }

        var displayName: String {
            switch self {
            case .lavender: return "Lavender"
            case .ocean:    return "Ocean Blue"
            case .sage:     return "Sage Green"
            case .coral:    return "Coral"
            case .gold:     return "Gold"
            case .slate:    return "Slate"
            }
        }
    }

    static var currentAccentOption: AccentOption {
        let raw = UserDefaults.standard.string(forKey: "accentColor") ?? AccentOption.lavender.rawValue
        return AccentOption(rawValue: raw) ?? .lavender
    }

    // MARK: - Signature Colors

    /// User-selected accent color, made text-safe against the live theme surface.
    ///
    /// The brand accents (lavender, gold, sage, …) are mid-tone hues that, used
    /// raw as foreground text/glyphs on the near-white light surface, fail WCAG
    /// AA badly (gold 2.26:1, lavender 2.77:1 on light `surfacePrimary`). Since
    /// the same token is read as a *foreground* across the consumer views and we
    /// can't touch those call sites, `accent` is luminance-shifted per surface —
    /// darkened on light surfaces, lightened on dark/mid surfaces — by exactly
    /// the amount needed to clear AA (see `textSafeAccent`). Measured against the
    /// actual surface constants this lifts accent-as-text from sub-AA to:
    ///   • light  P 5.70  S 5.21  E 4.74  (all AA; was 2.26–3.26)
    ///   • dark   P 5.70+ S 4.75+ E 3.97+ (P/S AA; was 5.03–7.24 P, elevated now ≥3:1)
    ///   • grey   P 5.70  S 4.52  E 3.63  (P/S AA; the grey palette's ceiling —
    ///            even pure white only reaches 4.26:1 on grey elevated)
    /// Hue is preserved (a luminance shift toward black/white), so the accent
    /// still reads as itself. `accentBrand` keeps the unshifted hue for fills.
    static var accent: Color {
        // Dynamic so it re-resolves on every theme-revision bump (golden hour,
        // day/night flip, grey toggle) just like the surface tokens — reading
        // the revision trait registers the dependency; the value comes from the
        // freshest snapshot.
        Color(UIColor { traitCollection in
            _ = traitCollection.themeRevision
            return Self.textSafeAccent.uiColor
        })
    }

    /// Unshifted brand hue — for accent *fills*, capsule backgrounds, gauge arcs,
    /// and large iconography where contrast is carried by the fill, not the hue.
    /// `accent` (text-safe) and `accentBrand` (fill) intentionally diverge.
    static var accentBrand: Color { currentAccentOption.color }

    static var accentLight: Color { accent.opacity(0.7) }
    static var accentSubtle: Color { accentBrand.opacity(0.15) }
    static var accentUIColor: UIColor { currentAccentOption.uiColor }

    // MARK: - On-Accent / Contrasting Foreground

    /// Foreground (text/glyph) color to use *on an accent FILL* — e.g. a primary
    /// button filled with `accentBrand`, a selected-state capsule, a badge whose
    /// background is the accent. Use this **instead of hardcoded `.white`**: the
    /// brand accents are mid-tone/light hues (lavender, gold, sage, coral, …), so
    /// white-on-fill fails WCAG AA in light/grey/dynamic-day (white lands
    /// 2.41–3.47:1 on the current swatches). `onAccent` returns a dark glyph color
    /// when the accent fill is light and white when it's dark — picked from the
    /// live accent's luminance — so on-fill text clears AA on every accent
    /// (current swatches: 5.03–7.24:1).
    ///
    /// Dynamic so it re-resolves on every theme-revision bump, matching `accent`.
    /// (The accent itself is theme-independent, but staying dynamic keeps it
    /// consistent should a future accent become surface-derived.)
    static var onAccent: Color {
        Color(UIColor { traitCollection in
            _ = traitCollection.themeRevision
            return ContrastRatio.contrastingForeground(on: currentAccentOption.rgb).uiColor
        })
    }

    /// `onAccent` as an `RGBColor`, for UIKit map glyphs and snapshot rendering
    /// that resolve a concrete value rather than a dynamic SwiftUI `Color`.
    static var onAccentRGB: RGBColor { ContrastRatio.contrastingForeground(on: currentAccentOption.rgb) }

    /// Legible foreground for an arbitrary solid FILL — black/near-black when the
    /// fill is light, white/near-white when it's dark, per WCAG luminance. Use on
    /// semantic fills whose color isn't the accent: traffic-status badges, the
    /// category chip glyph when the chip is filled with its category color, a
    /// `warmRed`/`sage`/`amber` pill. Clears AA (≥4.5:1) on every Steddi fill as
    /// normal text and comfortably ≥3:1 for large/badge text.
    ///
    /// For text drawn *on a surface* in a semantic color (not on a fill), use the
    /// surface-adaptive text tokens (`sageText`, `amberText`, `legibleText(_:)`)
    /// instead — those preserve the semantic hue; this picks black or white.
    static func contrastingForeground(on color: RGBColor) -> Color {
        ContrastRatio.contrastingForeground(on: color).color
    }

    /// Per-surface luminance-shifted accent that meets WCAG AA as foreground
    /// text. Dynamic so it re-resolves on every theme-revision bump exactly like
    /// the surface tokens; reads the live `ThemeEngine.snapshot.surfacePrimary`.
    private static var textSafeAccent: RGBColor {
        textSafeAccent(currentAccentOption.rgb, onSurface: ThemeEngine.snapshot.surfacePrimary)
    }

    /// AA target measured against `surfacePrimary`. Set above the 4.5 floor so
    /// the slightly-lower-contrast `surfaceSecondary` (and most of `surface
    /// Elevated`) also clear AA from the same shift — most accent-as-text sits on
    /// primary/secondary. Mid-tone (grey) surfaces lack the headroom to reach
    /// this even at the cap, so they land at the best the palette allows.
    private static let accentTextTarget: Double = 5.7
    /// Cap on the luminance shift so the accent stays recognisably itself rather
    /// than collapsing to pure black/white when a surface is low on headroom.
    private static let accentShiftCap: Double = 0.85

    /// Pure, testable mapping from a brand accent + the surface it sits on to a
    /// text-safe accent. Light surfaces darken the accent; dark and mid-tone
    /// surfaces lighten it (the only direction with headroom against a ~0.4 grey
    /// surface). The minimal shift that reaches `accentTextTarget` is found by
    /// bisection and clamped to `accentShiftCap`; hue is preserved throughout.
    static func textSafeAccent(_ base: RGBColor, onSurface surface: RGBColor) -> RGBColor {
        ContrastRatio.legible(base, onSurface: surface, target: accentTextTarget, cap: accentShiftCap)
    }

    /// Sage green — "all clear" / "good to go" states.
    /// Single source of truth is `sageRGB`; `sage` is the fill/dark-surface hue.
    static let sageRGB = RGBColor(0.13, 0.74, 0.45)                     // #22BD73
    static let sage = sageRGB.color
    static let sageSubtle = sageRGB.color.opacity(0.15)

    /// Soft red — warnings, delays, problems. Not alarming.
    static let warmRedRGB = RGBColor(0.91, 0.30, 0.24)                  // #E84D3D
    static let warmRed = warmRedRGB.color
    static let warmRedSubtle = warmRedRGB.color.opacity(0.15)
    /// Over-limit warning amber, independent of accent.
    static let warningAmberRGB = RGBColor(0.95, 0.65, 0.15)             // #F2A626
    static let warningAmber = warningAmberRGB.color

    // MARK: - Semantic colors AS TEXT (surface-adaptive, hue-preserving)

    /// The semantic hues above are sized as *fills* and dark-surface text. As
    /// foreground TEXT on the app surfaces they fail WCAG AA in light/grey
    /// (sage 2.30:1, amber 1.92:1, warmRed 1.77:1 on the worst-case surface) —
    /// they're saturated mid/high-luminance colors that vanish on a near-white or
    /// grey background. `legibleText(_:)` shifts a semantic color toward the side
    /// the live surface has headroom in (darken on light, lighten on dark/grey) by
    /// the minimal amount that clears AA, preserving hue so the meaning survives
    /// (amber still reads as warning, sage as go). Dynamic, so it re-resolves on
    /// every theme-revision bump just like `accent`/the surfaces.
    ///
    /// USAGE RULE — text vs fill:
    ///   • Drawing a VALUE/label in a semantic color (distance in sage,
    ///     over-limit speed in amber, a status word in warmRed) ON a surface:
    ///     use `sageText` / `amberText` / `warmRedText` (or `legibleText(c)`).
    ///   • Drawing on a semantic/accent FILL (white-on-color badge/button):
    ///     use `onAccent` (accent fill) or `contrastingForeground(on:)` (other).
    ///   • Pure decoration / large glyphs / gauge arcs where contrast is carried
    ///     by size or fill, not legibility of small text: the raw `sage`/`warmRed`
    ///     /`warningAmber` hues are fine.
    static var sageText: Color { legibleText(sageRGB) }
    static var amberText: Color { legibleText(warningAmberRGB) }
    static var warmRedText: Color { legibleText(warmRedRGB) }

    /// AA target for semantic text, measured on `surfacePrimary`. Matches the
    /// accent text target (5.7) so a shift sized on primary also clears AA on
    /// secondary and the 3:1 floor on elevated, across light/dark; grey lands at
    /// the palette ceiling (≥4.5 on primary, ≥3:1 on secondary).
    private static let semanticTextTarget: Double = 5.7

    /// Make an arbitrary semantic hue legible as foreground text on the live
    /// surface, preserving its hue. Dynamic; pairs with `contrastingForeground`
    /// for the on-fill case.
    static func legibleText(_ base: RGBColor) -> Color {
        Color(UIColor { traitCollection in
            _ = traitCollection.themeRevision
            return Self.legibleText(base, onSurface: ThemeEngine.snapshot.surfacePrimary).uiColor
        })
    }

    /// Pure, testable mapping behind `legibleText` / `sageText` / `amberText`.
    /// Delegates to the shared `ContrastRatio.legible` shifter against the given
    /// surface; same machinery as `textSafeAccent`, sized for semantic text.
    static func legibleText(_ base: RGBColor, onSurface surface: RGBColor) -> RGBColor {
        ContrastRatio.legible(base, onSurface: surface, target: semanticTextTarget, cap: accentShiftCap)
    }

    /// Surface colors — resolved by ThemeEngine. The dark/light endpoints are
    /// pixel-identical to the old trait-adaptive values (see ThemePalette);
    /// dynamic mode interpolates between them, through grey when enabled.
    ///
    /// Views keep reading these statics unchanged — the facade hides the engine
    /// entirely. Each color is a *dynamic* `Color(UIColor { ... })`: the UIKit
    /// provider re-resolves whenever a trait it reads changes, and it reads the
    /// custom `ThemeRevisionTrait`. The app root bumps that trait on every
    /// `.steddiDynamicThemeUpdated`, so a golden-hour / temperature / tunnel
    /// step propagates as a trait change through the whole hosted tree and every
    /// dynamic color re-resolves against the freshest `ThemeEngine.snapshot` —
    /// no body needs to read the engine and no `@State` is rebuilt. Non-reactive
    /// call sites (UIKit map surfaces, snapshots) still get a correct value
    /// because the provider also resolves eagerly from the current snapshot.
    static var surfacePrimary: Color { dynamicColor { $0.surfacePrimary } }
    static var surfaceSecondary: Color { dynamicColor { $0.surfaceSecondary } }
    static var surfaceElevated: Color { dynamicColor { $0.surfaceElevated } }

    /// Text — resolved by ThemeEngine alongside the surfaces.
    static var textPrimary: Color { dynamicColor { $0.textPrimary } }
    static var textSecondary: Color { dynamicColor { $0.textSecondary } }
    static var textMuted: Color { dynamicColor { $0.textMuted } }

    // MARK: - Fixed light-on-dark (onboarding cinematic backdrop)

    /// The onboarding showpiece floats its beats on a FIXED dark cinematic
    /// backdrop (`OnboardingView.beatBackground = .black` + the showpiece card's
    /// black/accent gradient), independent of the resolved app theme. The
    /// adaptive `textPrimary/textSecondary/textMuted` tokens resolve near-black in
    /// the Light theme (and dynamic-by-day), so card copy drawn in them collapses
    /// to near-black-on-black and is illegible there. These fixed light tiers
    /// keep that copy readable in EVERY theme — the same rule the skip footer
    /// already follows with `.white.opacity(0.85)`. Use ONLY for text/glyphs
    /// inside the onboarding beats; everywhere else the adaptive theme tokens are
    /// correct.
    ///
    /// CONTRAST — both surfaces the copy sits on are now DARK:
    ///   • The hero/footer chrome sits directly on the near-black backdrop, where
    ///     even the muted tier is far above AA.
    ///   • The showcase/ask beats (routeRules / turnByTurn / permissions /
    ///     theme / emergency) render *inside* the morphing Liquid Glass card.
    ///     That neutral `.regular` glass over the dark backdrop USED to render as
    ///     a LIGHT frost (~0.73 sRGB), and white-on-light-frost collapsed to
    ///     ~1.9:1 — the recurring legibility bug. `OnboardingShowpieceCard` now
    ///     paints a deterministic DARK scrim behind the content of those beats
    ///     (`OnboardingShowcaseFrost.surface` ≈ RGB 0.22), so the copy is reliably
    ///     white-on-dark, like the hero. Against that surface the tiers clear AA
    ///     with margin: primary 11.6:1, secondary (.92) 9.7:1, muted (.66) 4.9:1.
    ///     The three tiers stay visually ranked (primary > secondary > muted).
    ///
    /// The decorative graphic strokes (route-rules dashed reject line, speedo
    /// track) layer their own `.opacity(...)` on top of `onboardingTextMuted`;
    /// on the dark scrim they read ~3.2:1 — quiet but above the graphical floor.
    static let onboardingTextPrimary = Color.white
    static let onboardingTextSecondary = Color.white.opacity(0.92)
    static let onboardingTextMuted = Color.white.opacity(0.66)

    /// Fixed dark surface for the onboarding card's Reduce-Transparency / high-
    /// contrast fallback fill. When glass is unavailable, `steddiGlass` paints a
    /// solid `fallbackFill`; the default `surfaceSecondary` is near-WHITE in the
    /// Light theme, which would make the card a light box under the fixed-white
    /// onboarding copy. This keeps the card dark so that copy stays legible in
    /// every theme even with Reduce Transparency on.
    static let onboardingCardFallbackFill = Color(red: 0.12, green: 0.12, blue: 0.13)

    /// `onboardingCardFallbackFill` as an `RGBColor`, for the contrast math /
    /// snapshot rendering that must resolve a concrete value. This is the surface
    /// the theme beat's copy is contrasted against when Liquid Glass is
    /// unavailable (Reduce Transparency / Increase Contrast): `steddiGlass` then
    /// paints this solid dark fill instead of the live accent-tinted glass, so
    /// the on-surface foreground must flip to near-WHITE — not the near-black it
    /// resolves to over the bright accent glass — or the copy goes invisible.
    static let onboardingCardFallbackFillRGB = RGBColor(0.12, 0.12, 0.13)

    // MARK: - Over-map glass scrim (nav HUD legibility)

    /// True when the resolved app theme is DARK (the nav overlay pins the live
    /// app theme, so this matches what the HUD actually renders in). Read by the
    /// over-map scrim so the dark-theme washout fix never touches the
    /// already-approved light-theme HUD.
    static var prefersDarkChrome: Bool { ThemeEngine.snapshot.prefersDarkChrome }

    /// Opacity for the scrim painted *behind* nav glass over the moving map.
    ///
    /// THE DARK-THEME WASHOUT FIX. Neutral/lightly-tinted `.regular` Liquid Glass
    /// over a DARK map renders as a LIGHT frost (the codebase's own sampled
    /// ~0.73 sRGB — see `OnboardingShowcaseFrost`), so the HUD's near-white
    /// `textPrimary` readouts collapsed to ~1.8:1 in dark theme (measured). A
    /// faint scrim *behind* the glass can't fix it: the translucent frost
    /// composites over the scrim and dominates. The proven onboarding remedy is a
    /// near-opaque luminance-FIXED dark scrim — dark enough that the adaptive
    /// glass renders DARK against it, so the readout sits white-on-dark.
    ///
    /// In LIGHT theme the HUD already reads fine (near-black text on the light
    /// frost, ~9–12:1) and the look is user-approved, so the scrim stays the
    /// original faint wash there and nothing changes. High contrast already forces
    /// the glass fully opaque, so the scrim is irrelevant then.
    static func mapGlassScrimOpacity(highContrast: Bool) -> Double {
        if highContrast { return 0 }            // glass is opaque under high contrast
        return prefersDarkChrome ? 0.9 : 0.22   // dark: near-opaque dark; light: original faint wash
    }

    /// Fill for the over-map scrim. In dark theme it's the luminance-FIXED dark
    /// `onboardingCardFallbackFill` (so the panel composite is reliably dark
    /// regardless of how light the live glass renders); in light theme it's the
    /// original adaptive `surfacePrimary` faint wash (unchanged, approved look).
    static var mapGlassScrimFill: Color { prefersDarkChrome ? onboardingCardFallbackFill : surfacePrimary }

    /// The deterministic dark surface the dark-theme HUD readouts effectively sit
    /// on after the scrim fix — the near-opaque fixed-dark scrim composited over a
    /// representative dark map tile. Mirrors `OnboardingShowcaseFrost.surface`:
    /// the contrast math is sized against this worst-case (no-lighter-than)
    /// composite, which the real adaptive-glass render then beats.
    static let mapGlassDarkScrimSurface = RGBColor(0.118, 0.118, 0.128)

    /// Build a dynamic SwiftUI color whose UIKit provider (a) reads the live
    /// `ThemeEngine.snapshot` so the value is always current, and (b) touches
    /// `traitCollection.themeRevision` so the provider registers a dependency on
    /// the theme-revision trait and is re-invoked when the root bumps it.
    private static func dynamicColor(
        _ select: @escaping (ThemeState) -> RGBColor
    ) -> Color {
        Color(UIColor { traitCollection in
            // Reading the revision establishes the trait dependency that drives
            // re-resolution; the value itself is otherwise unused here.
            _ = traitCollection.themeRevision
            return select(ThemeEngine.snapshot).uiColor
        })
    }

    // MARK: - Typography

    /// Upper bound on the OS Dynamic Type category we honour for scaling. The
    /// nav HUD lives in fixed-height chrome over a moving map, so the maneuver
    /// banner / speedometer must grow with the system Larger Text setting but not
    /// explode. We track the live setting up through the first accessibility step
    /// (`.accessibilityExtraLarge`, well past XXL); past that the *metric* is
    /// clamped here so the largest accessibility sizes stay bounded. Standard
    /// (non-accessibility) sizes through XXL are honoured exactly.
    private static let dynamicTypeCeiling: UIContentSizeCategory = .accessibilityExtraLarge

    /// Scale a fixed base point size by the OS Dynamic Type setting so every
    /// `SteddiTheme.*`-driven label responds to Settings ▸ Display ▸ Text Size /
    /// Larger Text — the foundational fix that propagates to every consumer
    /// without touching call sites.
    ///
    /// `UIFontMetrics` maps the base size through the user's content-size
    /// category (the same curve UIKit/SwiftUI text styles use). We resolve
    /// against the *live* category but never above `dynamicTypeCeiling`, capping
    /// growth so the in-nav HUD stays bounded while still supporting at least XXL.
    /// Reading `UIScreen.main.traitCollection` here also makes the font re-derive
    /// when the OS setting changes (SwiftUI rebuilds text on a content-size-
    /// category change). The app's own passenger/accessibility `textScale`
    /// multiplier is already folded into `size` by call sites (e.g.
    /// `mono(26 * textScale)`), so it composes multiplicatively on top of OS
    /// Dynamic Type — the intended layering, which only meaningfully stacks in the
    /// app's accessibility display mode.
    private static func scaled(_ size: CGFloat) -> CGFloat {
        let live = UITraitCollection.current.preferredContentSizeCategory
        let effective = min(live, dynamicTypeCeiling)
        let metrics = UITraitCollection(preferredContentSizeCategory: effective)
        return UIFontMetrics.default.scaledValue(for: size, compatibleWith: metrics)
    }

    /// Confident, weighted heading style
    static func heading(_ size: CGFloat = 20) -> Font {
        .system(size: scaled(size), weight: .bold, design: .rounded)
    }

    /// Body text — clean and readable
    static func body(_ size: CGFloat = 16) -> Font {
        .system(size: scaled(size), weight: .regular, design: .default)
    }

    /// Mono for numbers (ETAs, times, distances)
    static func mono(_ size: CGFloat = 15) -> Font {
        .system(size: scaled(size), weight: .medium, design: .monospaced)
    }

    // MARK: - High Contrast (accessibility mode)

    /// Body text that thickens for high-contrast reading.
    static func body(_ size: CGFloat, highContrast: Bool) -> Font {
        .system(size: scaled(size), weight: highContrast ? .semibold : .regular, design: .default)
    }

    /// Secondary text promoted to full contrast when high contrast is on.
    static func textSecondary(highContrast: Bool) -> Color {
        highContrast ? textPrimary : textSecondary
    }

    /// Muted text promoted one contrast level when high contrast is on.
    static func textMuted(highContrast: Bool) -> Color {
        highContrast ? textSecondary : textMuted
    }

    /// Floating nav surfaces go fully opaque under high contrast so text
    /// never fights the map underneath.
    static func navSurfaceOpacity(_ base: Double, highContrast: Bool) -> Double {
        highContrast ? 1.0 : base
    }

    /// Hairline card strokes thicken to a visible border under high contrast.
    static func navStrokeOpacity(_ base: Double, highContrast: Bool) -> Double {
        highContrast ? max(base, 0.45) : base
    }

    // MARK: - Corner Radii

    static let radiusSmall: CGFloat = 10
    static let radiusMedium: CGFloat = 16
    static let radiusLarge: CGFloat = 24
    static let radiusCard: CGFloat = 20

    // MARK: - Map Configuration

    /// Shared map style for every map surface. MapKit silently ignores
    /// `showsTraffic` under `.muted` emphasis, so traffic surfaces use `.default`.
    /// POIs stay visible unless a surface opts out via `poiFilter` — the no-go
    /// editor and planner rely on POI labels for picking places.
    static func mapConfiguration(
        traffic: Bool,
        poiFilter: MKPointOfInterestFilter? = nil
    ) -> MKStandardMapConfiguration {
        let config = MKStandardMapConfiguration(
            elevationStyle: .flat,
            emphasisStyle: traffic ? .default : .muted
        )
        config.showsTraffic = traffic
        if let poiFilter {
            config.pointOfInterestFilter = poiFilter
        }
        return config
    }

    // MARK: - Traffic Status

    enum TrafficStatus {
        case clear, moderate, heavy, unknown

        /// FILL / dot / arc color — the raw semantic hue. Use behind a
        /// `contrastingForeground(on:)` glyph for filled badges.
        var color: Color {
            switch self {
            case .clear: return SteddiTheme.sage
            case .moderate: return SteddiTheme.accentBrand
            case .heavy: return SteddiTheme.warmRed
            case .unknown: return SteddiTheme.textMuted
            }
        }

        /// TEXT color — the surface-adaptive, AA-legible variant of `color` for
        /// status words/values drawn directly on a surface (not on a fill).
        /// `clear`/`moderate`/`heavy` use the legible semantic/accent text
        /// tokens; `unknown` is already a surface-adaptive muted token.
        var textColor: Color {
            switch self {
            case .clear: return SteddiTheme.sageText
            case .moderate: return SteddiTheme.accent
            case .heavy: return SteddiTheme.warmRedText
            case .unknown: return SteddiTheme.textMuted
            }
        }

        var label: String {
            switch self {
            case .clear: return "Clear"
            case .moderate: return "Moderate"
            case .heavy: return "Heavy"
            case .unknown: return "—"
            }
        }
    }
}

// MARK: - Steady Pulse Motif

/// The signature "steady line" visual — a flat, calm line that subtly pulses.
/// Used as a brand element on cards, headers, dividers.
///
/// The pulse is a gentle opacity breathe that loops forever. It is gated by
/// ``SteddiMotion``: under Reduce Motion `phase` is set instantly to its rest
/// value and never animates, so the line renders as a static, full-presence
/// gradient — no motion, no flicker.
struct SteadyLine: View {
    var color: Color = SteddiTheme.accent
    var height: CGFloat = 2

    /// 0 = rest (full presence), 1 = the dimmest point of the breathe.
    @State private var phase: CGFloat = 0

    /// Opacity travels between full and `pulseFloor` as `phase` breathes.
    private var pulseFloor: CGFloat { 0.55 }

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.0), color, color, color.opacity(0.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: height)
            .opacity(1 - phase * (1 - pulseFloor))
            .onAppear {
                guard SteddiMotion.shouldAnimate else { return }
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }
}

/// Amber-tinted glass background for Steddi's floating cards
struct SteddiCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                    .fill(SteddiTheme.surfacePrimary.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                            .stroke(SteddiTheme.accent.opacity(0.12), lineWidth: 1)
                    )
            }
    }
}

// MARK: - Theme Mode

enum ThemeMode: String, CaseIterable {
    case dark, light, dynamic

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .dynamic: return "Dynamic"
        }
    }

    /// Resolve the current color scheme based on mode and time of day
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .dynamic: return Self.isDaytime ? .light : .dark
        }
    }

    var mapInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .dynamic: return Self.isDaytime ? .light : .dark
        }
    }

    /// Calculate whether the sun is up using the user's actual location and solar math.
    /// Falls back to 7am-7pm only when no real location is available.
    static var isDaytime: Bool {
        // Prefer the process-wide last-known fix the live location feed
        // publishes (LastKnownLocation) — a freshly-created CLLocationManager's
        // `.location` read cold is almost always nil, which is what silently
        // killed the accurate solar check and forced the clock fallback. A cold
        // manager can still occasionally return CoreLocation's process cache, so
        // try it as a secondary source before falling back to the clock.
        let coord = LastKnownLocation.current ?? CLLocationManager().location?.coordinate
        guard let coord else {
            // No real location anywhere — fall back to simple time check.
            let hour = Calendar.current.component(.hour, from: Date())
            return hour >= 7 && hour < 19
        }
        return sunIsUp(at: coord, date: Date())
    }

    /// Solar calculation — determines if the sun is above the horizon at a given coordinate and time.
    /// Uses UTC time + longitude to derive local solar time — independent of device timezone.
    static func sunIsUp(at coordinate: CLLocationCoordinate2D, date: Date) -> Bool {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .gmt

        let dayOfYear = Double(utcCal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let lat = coordinate.latitude
        let lon = coordinate.longitude

        // Solar declination
        let declination = -23.44 * cos(2.0 * .pi / 365.0 * (dayOfYear + 10))

        // Hour angle at sunrise/sunset
        let latRad = lat * .pi / 180.0
        let decRad = declination * .pi / 180.0
        let cosHourAngle = -tan(latRad) * tan(decRad)

        // Handle polar day/night
        if cosHourAngle < -1 { return true }   // Midnight sun
        if cosHourAngle > 1 { return false }   // Polar night

        let hourAngle = acos(cosHourAngle) * 180.0 / .pi
        let sunriseOffset = hourAngle / 15.0  // degrees to hours

        // Local solar time from UTC + longitude (15° per hour)
        let utcHour = Double(utcCal.component(.hour, from: date)) + Double(utcCal.component(.minute, from: date)) / 60.0
        var localSolarHour = (utcHour + lon / 15.0).truncatingRemainder(dividingBy: 24.0)
        if localSolarHour < 0 { localSolarHour += 24.0 }

        let sunrise = 12.0 - sunriseOffset
        let sunset = 12.0 + sunriseOffset

        return localSolarHour >= sunrise && localSolarHour < sunset
    }
}

extension SteddiTheme {
    /// Legacy mode, still read by map surfaces. The `"themeMode"` key is a
    /// shadow kept in sync with `ThemeModeEx` (grey projects to light here).
    static var currentThemeMode: ThemeMode {
        let raw = UserDefaults.standard.string(forKey: "themeMode") ?? ThemeMode.dynamic.rawValue
        return ThemeMode(rawValue: raw) ?? .dark
    }

    /// The user's actual selected mode, grey included.
    static var currentThemeModeEx: ThemeModeEx { ThemeModeEx.current() }
}

// MARK: - Notifications

extension Notification.Name {
    static let steddiAccentColorChanged = Notification.Name("steddiAccentColorChanged")
    static let steddiThemeModeChanged = Notification.Name("steddiThemeModeChanged")
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 20) {
            SteadyLine()
                .padding(.horizontal, 40)

            SteddiCard {
                HStack {
                    Image(systemName: "house.fill")
                        .foregroundStyle(SteddiTheme.accent)
                    Text("Home")
                        .font(SteddiTheme.heading(16))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Spacer()
                    Text("12 min")
                        .font(SteddiTheme.mono(14))
                        .foregroundStyle(SteddiTheme.sage)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}
