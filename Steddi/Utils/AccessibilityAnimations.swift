import SwiftUI

/// Global Reduce Motion gate for every Steddi custom animation.
///
/// One decision point: ``shouldAnimate`` reads `UIAccessibility.isReduceMotionEnabled`,
/// and ``resolve(_:)`` returns `nil` (an instant change) when motion is reduced.
/// TransitionKit's animation getters all route through here, so honoring the
/// system preference is automatic for any call site that uses the kit.
enum SteddiMotion {

    /// True when the system is configured to play animations normally.
    static var shouldAnimate: Bool {
        !UIAccessibility.isReduceMotionEnabled
    }

    /// The given animation, or `nil` (instant) under Reduce Motion. Passing the
    /// result to `withAnimation(_:)` or `.animation(_:value:)` yields an instant
    /// state change when motion is reduced.
    static func resolve(_ animation: Animation) -> Animation? {
        shouldAnimate ? animation : nil
    }

    /// Run `body` inside `withAnimation(resolve(animation))`, so the change is
    /// instant under Reduce Motion and animated otherwise.
    static func withMotion<Result>(
        _ animation: Animation,
        _ body: () throws -> Result
    ) rethrows -> Result {
        try withAnimation(resolve(animation), body)
    }
}

// MARK: - View modifiers

extension View {
    /// Apply an animation that is automatically gated by Reduce Motion.
    /// Equivalent to `.animation(SteddiMotion.resolve(animation), value:)`.
    func steddiAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.animation(SteddiMotion.resolve(animation), value: value)
    }
}

/// Button style giving a Reduce-Motion-aware press-scale feedback. The scale is
/// skipped entirely when motion is reduced (haptics still fire at the call site).
struct SteddiPressStyle: ButtonStyle {
    var scale: CGFloat = TransitionKit.pressScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(SteddiMotion.shouldAnimate && configuration.isPressed ? scale : 1.0)
            .animation(TransitionKit.buttonSpring, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SteddiPressStyle {
    /// A spring press-scale button style, gated by Reduce Motion.
    static var steddiPress: SteddiPressStyle { SteddiPressStyle() }
}
