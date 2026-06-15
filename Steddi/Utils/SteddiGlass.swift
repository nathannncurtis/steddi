import SwiftUI

/// Steddi's single tuning point for Apple's Liquid Glass (iOS 26).
///
/// Glass is reserved for *floating chrome over the map* (nav controls, search,
/// the sheet tab pill, route/reroute cards, the speedometer housing) and the
/// primary action buttons. Static, opaque content (Settings rows, sheet bodies,
/// list backgrounds) stays on the existing ``SteddiTheme`` surfaces.
///
/// Every adoption flows through the ``SwiftUI/View/steddiGlass(tint:interactive:in:fallbackFill:fallbackStrokeOpacity:)``
/// modifier and ``SteddiGlassButtonStyle`` so tint, interactivity, and the
/// Reduce-Transparency / high-contrast fallback are decided in exactly one
/// place — mirroring how ``SteddiTheme`` (color) and ``SteddiMotion`` /
/// ``TransitionKit`` (motion) centralize the rest of the visual language.
enum SteddiGlass {

    /// Glass is suppressed entirely when the user asks for less transparency,
    /// or when the app's own high-contrast display mode is on (which already
    /// forces opaque nav surfaces). Read at the call site via the modifier below.
    @MainActor static var isAvailable: Bool {
        !UIAccessibility.isReduceTransparencyEnabled
        && !DisplayModeService.shared.useHighContrast
    }

    /// Default corner radii reused from ``SteddiTheme`` so glass shapes match the
    /// existing rounded-rect language.
    static let cardShape   = RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)   // 20
    static let mediumShape = RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium) // 16
}

// MARK: - The core modifier

extension View {
    /// Apply Steddi's Liquid Glass treatment, or a solid ``SteddiTheme`` fallback
    /// when glass is unavailable (Reduce Transparency / high-contrast mode), so
    /// nothing regresses for those users.
    ///
    /// - Parameters:
    ///   - tint: accent tint for the glass; `nil` for neutral `.regular`.
    ///   - interactive: pass `true` for tappable controls so the glass reacts to
    ///     touch (lensing / highlight). Plain content passes `false`.
    ///   - shape: clipping shape; defaults to the card rounded-rect.
    ///   - fallbackFill: the opaque fill used when glass is off.
    ///   - fallbackStrokeOpacity: hairline stroke opacity used when glass is off.
    @ViewBuilder
    func steddiGlass(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: some Shape = SteddiGlass.cardShape,
        fallbackFill: Color = SteddiTheme.surfacePrimary,
        fallbackStrokeOpacity: Double = 0.12
    ) -> some View {
        if SteddiGlass.isAvailable {
            // Build the Glass value: regular base, optional accent tint, optional
            // interactivity. There is no `isEnabled:` parameter on `glassEffect`
            // in this SDK — interactivity is a property of the Glass value.
            let glass: Glass = {
                var g = Glass.regular
                if let tint { g = g.tint(tint) }
                if interactive { g = g.interactive() }
                return g
            }()
            self.glassEffect(glass, in: shape)
        } else {
            // Exact current look: opaque-ish surface + hairline accent stroke,
            // honoring high-contrast promotion the same way nav chrome does.
            let highContrast = DisplayModeService.shared.useHighContrast
            self.background {
                shape
                    .fill(
                        fallbackFill.opacity(
                            SteddiTheme.navSurfaceOpacity(0.9, highContrast: highContrast)
                        )
                    )
                    .overlay(
                        shape.stroke(
                            (tint ?? SteddiTheme.accent).opacity(
                                SteddiTheme.navStrokeOpacity(fallbackStrokeOpacity, highContrast: highContrast)
                            ),
                            lineWidth: 1
                        )
                    )
            }
        }
    }
}

// MARK: - The glass control style — floating capsule/circle buttons

/// A self-contained glass button style that keeps Steddi's Reduce-Motion-aware
/// press-scale feedback (unlike Apple's `.buttonStyle(.glass)`, which would drop
/// the `.steddiPress` scale the app relies on). Reserve Apple's `.glassProminent`
/// for genuine system-styled primary CTAs where the stock press behavior is
/// wanted (Start / Get Started).
struct SteddiGlassButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(SteddiMotion.shouldAnimate && configuration.isPressed ? TransitionKit.pressScale : 1)
            .animation(TransitionKit.buttonSpring, value: configuration.isPressed)
            .steddiGlass(tint: tint, interactive: true, in: Capsule())
    }
}

extension ButtonStyle where Self == SteddiGlassButtonStyle {
    static var steddiGlass: SteddiGlassButtonStyle { SteddiGlassButtonStyle() }
    static func steddiGlass(tint: Color?) -> SteddiGlassButtonStyle { .init(tint: tint) }
}

// MARK: - The canonical primary CTA — `.buttonStyle(.steddiPrimary)`

/// Steddi's **one** prominent primary call-to-action style, used app-wide.
///
/// This is the foundation that kills the recurring CTA-contrast bug. The bug:
/// primary buttons were built with `.buttonStyle(.glassProminent).tint(accent)`,
/// which forces a **white** label regardless of the fill. The brand accents
/// (lavender, gold, sage, coral, …) are mid-tone/light hues, so white-on-fill
/// fails WCAG AA on most accents (white lands ~2.4–3.5:1 on the current
/// swatches — see `ThemeContrastTests.whiteOnAccentRegression`). The fix is to
/// pin the *pairing that clears AA*:
///   - **fill** = ``SteddiTheme/accentBrand`` (the unshifted brand hue) applied
///     as an **interactive glass tint** on a `Capsule`, via the shared
///     `steddiGlass(tint:interactive:in:)` modifier — so tint, interactivity,
///     and the Reduce-Transparency / high-contrast fallback are decided in one
///     place, exactly like every other glass adoption.
///   - **label** = ``SteddiTheme/onAccent`` — black-on-light-fill or
///     white-on-dark-fill picked from the live accent's luminance, which clears
///     AA on every brand accent (current swatches 5.03–7.24:1).
///
/// Deliberately NOT `.white` (fails AA on light accents), NOT `.glassProminent`
/// (forces a white label and the stock press behavior), and NOT the
/// surface-adaptive text-safe ``SteddiTheme/accent`` (that token is sized for
/// text drawn *on a surface*, not *on the accent fill* — on the fill it can
/// collapse toward the fill's own luminance).
///
/// Keeps Steddi's Reduce-Motion-aware press-scale (matching
/// ``SteddiGlassButtonStyle``) rather than `.glassProminent`'s stock press.
///
/// USAGE — provide the label like any SwiftUI `Button`; the style supplies the
/// fill and the legible foreground, so the label needs no `.foregroundStyle`:
/// ```swift
/// Button("Get Started") { start() }
///     .buttonStyle(.steddiPrimary)
///
/// Button { save() } label: {
///     Label("Save", systemImage: "checkmark")
///         .frame(maxWidth: .infinity)   // call sites still own sizing/padding
/// }
/// .buttonStyle(.steddiPrimary)
/// ```
///
/// RULE — **every accent primary CTA must use this**, never
/// `.glassProminent.tint(accent)` and never a hardcoded `.white` label on an
/// accent fill. Use `.steddiPrimary(tint:)` only for the rare prominent button
/// whose fill is intentionally a non-accent color (it still pairs the fill with
/// its AA-correct `onAccent`-style foreground).
struct SteddiPrimaryButtonStyle: ButtonStyle {
    /// The prominent fill. Defaults to the brand accent; pass another color only
    /// for a deliberately non-accent prominent CTA. The foreground is always the
    /// AA-correct on-fill pairing for whatever `tint` resolves to.
    var tint: Color = SteddiTheme.accentBrand

    /// AA-legible foreground for the current fill. When the fill is the brand
    /// accent this is exactly ``SteddiTheme/onAccent`` (re-resolves with the
    /// live accent). For a custom non-accent tint the style can't read the
    /// concrete RGB of an arbitrary `Color`, so it falls back to `onAccent`'s
    /// pairing for the brand accent — callers passing a custom tint should pick
    /// one whose on-fill foreground matches, or pass a fully-styled label.
    private var foreground: Color { SteddiTheme.onAccent }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Bold, legible label in the AA-correct on-fill color. Call sites
            // own sizing/padding (e.g. `.frame(maxWidth: .infinity)`); the style
            // owns weight + foreground + fill so the contrast can't regress.
            .fontWeight(.bold)
            .foregroundStyle(foreground)
            .scaleEffect(SteddiMotion.shouldAnimate && configuration.isPressed ? TransitionKit.pressScale : 1)
            .animation(TransitionKit.buttonSpring, value: configuration.isPressed)
            .steddiGlass(
                tint: tint,
                interactive: true,
                in: Capsule(),
                // When glass is off (Reduce Transparency / high contrast), paint
                // the fill solid so the CTA stays prominent and the on-fill
                // foreground stays legible against it.
                fallbackFill: tint
            )
    }
}

extension ButtonStyle where Self == SteddiPrimaryButtonStyle {
    /// The canonical primary CTA filled with the brand accent. See
    /// ``SteddiPrimaryButtonStyle``. Provide the label like any `Button`.
    static var steddiPrimary: SteddiPrimaryButtonStyle { SteddiPrimaryButtonStyle() }

    /// A prominent primary CTA with a non-accent fill, for the rare case one is
    /// needed. Defaults to `accentBrand`, so `.steddiPrimary` and
    /// `.steddiPrimary(tint:)` agree.
    static func steddiPrimary(tint: Color = SteddiTheme.accentBrand) -> SteddiPrimaryButtonStyle {
        .init(tint: tint)
    }
}

// MARK: - The destructive CTA — `.buttonStyle(.steddiDestructive)`

/// Steddi's destructive prominent action — End Navigation, Call emergency
/// contact, and any other "warm-red, do-this-deliberately" CTA.
///
/// Same machinery as ``SteddiPrimaryButtonStyle`` (interactive `warmRed` glass
/// tint on a `Capsule`, Reduce-Motion press-scale, solid `warmRed` fallback
/// when glass is off) — but the **foreground is the AA-correct on-fill color
/// for `warmRed`** rather than a hardcoded `.white`.
///
/// THE FIX THIS REPLACES: destructive buttons were drawn as `.white` text on a
/// `warmRed` fill (and the nav overlay used `.glassProminent.tint(warmRed)`,
/// which forces the same white label). White-on-warmRed is only ~3.79:1 — it
/// passes the 3.0 large-text floor for a bold ≥17pt label but FAILS the 4.5
/// body floor the codebase holds these semantic fills to
/// (`ThemeContrastTests.contrastingForegroundSemanticFillsAA`), and silently
/// drops below AA-large if `warmRed` is ever lightened or the label shrinks
/// under Dynamic Type. `contrastingForeground(on: warmRedRGB)` resolves to the
/// near-black on-fill glyph (warmRed luminance 0.227 > flip 0.179) at ~5.55:1,
/// clearing the full body floor with margin on every Dynamic-Type size.
///
/// USAGE — identical to `.steddiPrimary`; the style owns weight + foreground +
/// fill, so the label needs no `.foregroundStyle`:
/// ```swift
/// Button("End", action: end).buttonStyle(.steddiDestructive)
/// ```
struct SteddiDestructiveButtonStyle: ButtonStyle {
    /// AA-legible foreground for the warmRed fill — the near-black on-fill glyph
    /// (warmRed is mid-tone, luminance 0.227 > the 0.179 flip), at ~5.55:1.
    private var foreground: Color { SteddiTheme.contrastingForeground(on: SteddiTheme.warmRedRGB) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.bold)
            .foregroundStyle(foreground)
            .scaleEffect(SteddiMotion.shouldAnimate && configuration.isPressed ? TransitionKit.pressScale : 1)
            .animation(TransitionKit.buttonSpring, value: configuration.isPressed)
            .steddiGlass(
                tint: SteddiTheme.warmRed,
                interactive: true,
                in: Capsule(),
                // Solid warmRed when glass is off so the destructive CTA stays
                // prominent and the near-black on-fill label stays legible.
                fallbackFill: SteddiTheme.warmRed
            )
    }
}

extension ButtonStyle where Self == SteddiDestructiveButtonStyle {
    /// The canonical destructive CTA — warmRed glass fill with the AA-correct
    /// on-fill (near-black) label. See ``SteddiDestructiveButtonStyle``.
    static var steddiDestructive: SteddiDestructiveButtonStyle { SteddiDestructiveButtonStyle() }
}
