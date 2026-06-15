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
