import SwiftUI

/// Centralized animation timing, spring parameters, and reusable transition
/// definitions for Steddi's navigation and navigation-adjacent surfaces.
///
/// Every spring and curve here is tuned once so the whole app shares one motion
/// vocabulary: quick accent cross-fades, a standard overlay entrance, a slow
/// camera/route-draw ease, and a small family of springs (button press, floating
/// button entrance, arrival bounce). Animation getters route through
/// ``SteddiMotion`` so Reduce Motion degrades them to instant globally — call
/// sites never have to remember to check the flag.
enum TransitionKit {

    // MARK: - Durations

    /// Accent changes, toasts, color cross-fades.
    static let durationQuick: Double = 0.2
    /// Overlay / card / sheet entrance and exit.
    static let durationStandard: Double = 0.35
    /// Camera transitions, route draw-on.
    static let durationSlow: Double = 0.6

    /// Per-card stagger step for the commute card entrance.
    static let staggerStep: Double = 0.08
    /// Lead-in delay before the floating button spring fires, so the sheet and
    /// banner have started moving first.
    static let floatingButtonDelay: Double = 0.15
    /// Banner entrance trails the sheet by a beat.
    static let bannerDelay: Double = 0.05

    /// Route draw-on duration (matches the renderer's CADisplayLink schedule).
    static let routeDrawDuration: Double = 1.2

    // MARK: - Onboarding showpiece

    /// Autoplay dwell per showcase beat, before it auto-advances. A hands-off
    /// viewer sees the full reel; a tap on Next cancels the dwell and advances
    /// immediately. Disabled entirely under Reduce Motion / VoiceOver.
    static let onboardingBeatDwell: Double = 5.5

    /// Drives the morph of the single Liquid Glass card between beats — the
    /// glass shell springs between geometries as the inner content swaps.
    /// Reduce-Motion-aware: resolves to `nil` (instant) when motion is reduced.
    static var onboardingMorph: Animation? {
        SteddiMotion.resolve(.spring(response: 0.5, dampingFraction: 0.82))
    }

    /// The hero's glass wordmark plate materialize spring.
    static var onboardingWordmark: Animation? {
        SteddiMotion.resolve(.spring(response: 0.6, dampingFraction: 0.8))
    }

    // MARK: - Spring Parameters (response, dampingFraction)

    /// Button press feedback — snappy, minimal overshoot.
    static let springButton: (response: Double, damping: Double) = (0.4, 0.8)
    /// Floating button entrance — a touch of overshoot for delight.
    static let springFloatingButton: (response: Double, damping: Double) = (0.5, 0.75)
    /// Arrival celebration icon bounce — loose, visibly springy.
    static let springArrival: (response: Double, damping: Double) = (0.4, 0.6)
    /// Reroute card spring-in — slight Y overshoot as it slides up.
    static let springReroute: (response: Double, damping: Double) = (0.5, 0.7)

    // MARK: - Press feedback

    /// Scale applied while a button is held down.
    static let pressScale: CGFloat = 0.95

    // MARK: - Transitions

    /// Commute-card style: slides in from the leading edge while fading.
    static var steddiCard: AnyTransition {
        .opacity.combined(with: .move(edge: .leading))
    }

    /// Sheet / bottom-anchored card style: slides up from the bottom while fading.
    static var steddiSheet: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }

    /// Banner / toast style: drops in from the top while fading.
    static var steddiBanner: AnyTransition {
        .move(edge: .top).combined(with: .opacity)
    }

    // MARK: - Animations (Reduce-Motion aware)

    /// Quick fade for accent/color/toast changes.
    static var quickFade: Animation? {
        SteddiMotion.resolve(.easeInOut(duration: durationQuick))
    }

    /// Standard overlay / card entrance and exit.
    static var standardEntrance: Animation? {
        SteddiMotion.resolve(.easeInOut(duration: durationStandard))
    }

    /// Slow ease for camera transitions and the route draw-on.
    static var slowEase: Animation? {
        SteddiMotion.resolve(.easeInOut(duration: durationSlow))
    }

    /// Button press spring.
    static var buttonSpring: Animation? {
        SteddiMotion.resolve(spring(springButton))
    }

    /// Floating button entrance spring, delayed behind the sheet.
    static var floatingButtonEntrance: Animation? {
        SteddiMotion.resolve(spring(springFloatingButton).delay(floatingButtonDelay))
    }

    /// Arrival celebration icon bounce.
    static var arrivalBounce: Animation? {
        SteddiMotion.resolve(spring(springArrival))
    }

    /// Reroute card spring-in.
    static var rerouteSpringIn: Animation? {
        SteddiMotion.resolve(spring(springReroute))
    }

    /// Commute-card stagger: the entrance animation for the card at `index`.
    static func cardStagger(index: Int) -> Animation? {
        SteddiMotion.resolve(.easeInOut(duration: 0.25).delay(Double(index) * staggerStep))
    }

    // MARK: - Helpers

    /// Build a `.spring` from a (response, damping) tuple.
    static func spring(_ params: (response: Double, damping: Double)) -> Animation {
        .spring(response: params.response, dampingFraction: params.damping)
    }
}
