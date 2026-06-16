import SwiftUI

/// Showcase beat 2: "Your route, your rules." The first beat with *soul* — it
/// says what Steddi is *for* before the flow asks for anything. Renders as the
/// inner content of the morphing `OnboardingShowpieceCard` (no card chrome of
/// its own).
///
/// The motion graphic is lightweight on purpose (the spec calls for "no new
/// heavy renderer"): two `Path`s — a straight route that would barrel through a
/// highlighted "no-go" blob, and a re-routed path that curves cleanly around it —
/// drawn on with a `trim` animation so the line visibly *chooses the user's way*.
/// All motion is Reduce-Motion-gated: under Reduce Motion the re-routed path is
/// shown whole and static.
struct OnboardingRouteRulesView: View {
    /// Live accent — the re-route line and blob ring glow the chosen color.
    /// Taken as the `AccentOption` (not a resolved `Color`) so the view can
    /// derive both the raw hue for the subtle blob fill and a surface-aware
    /// *legible* hue for the glyphs that must read on the lighter frosted card.
    var accent: SteddiTheme.AccentOption = SteddiTheme.currentAccentOption

    /// The raw brand hue — used only for the soft blob *fill*, where contrast is
    /// carried by the fill, not the glyph.
    private var accentFill: Color { accent.color }

    /// Glyph color for the affordance illustrations (no-go ring, nosign symbol,
    /// re-route line). They sit on the card's deterministic DARK scrim (see
    /// `OnboardingShowcaseFrost`): the shared `legibleText` shift LIGHTENS the
    /// mid-tone accent to a uniform 5.7:1 on that dark surface, so every accent
    /// reads identically bright while staying recognisably the brand hue — well
    /// above the 3:1 graphical-object floor (the no-go ring at .85 opacity still
    /// clears it at ~4.6:1).
    private var glyphAccent: Color {
        SteddiTheme.legibleText(accent.rgb, onSurface: OnboardingShowcaseFrost.surface).color
    }

    @State private var drawProgress: CGFloat = 0

    var body: some View {
        VStack(spacing: 22) {
            graphic
                .frame(height: 150)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Your route, your rules")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    // The card floats on a fixed dark cinematic backdrop, not a
                    // theme surface, so copy must stay light in every resolved
                    // theme — a theme `textPrimary` resolves near-black in Light
                    // and vanishes here (mirrors the footer's fixed-white skip).
                    .foregroundStyle(SteddiTheme.onboardingTextPrimary)

                Text("Steddi sends you the way *you* want to go — your fallbacks, your no-go zones, your call.")
                    .font(.body)
                    .foregroundStyle(SteddiTheme.onboardingTextSecondary)
                    .multilineTextAlignment(.center)
                    // At the largest accessibility text sizes this paragraph would
                    // otherwise rely entirely on the card's outer ScrollView. Let it
                    // shrink modestly so the copy degrades gracefully instead of
                    // forcing the whole card to scroll on first read.
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(28)
        // Cap the beat copy at the app's Dynamic Type ceiling (.accessibility3 ==
        // SteddiTheme.dynamicTypeCeiling/.accessibilityExtraLarge), the same bound
        // the hero's SteddiTheme.heading() applies via UIFontMetrics. The raw
        // .title2/.body styles here would otherwise scale unbounded to AX5,
        // breaking the cinematic layout while the hero stays capped. Copy still
        // scales up to the cap.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your route, your rules. Steddi sends you the way you want to go — your fallbacks, your no-go zones, your call.")
        .onAppear {
            guard SteddiMotion.shouldAnimate else { drawProgress = 1; return }
            drawProgress = 0
            withAnimation(.easeInOut(duration: 1.6)) { drawProgress = 1 }
        }
    }

    // MARK: - Motion graphic

    private var graphic: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // A highlighted "no-go" blob the route must avoid.
            let blob = CGRect(x: w * 0.42, y: h * 0.30, width: w * 0.16, height: h * 0.34)

            ZStack {
                // Faint "straight through" path the user rejected.
                straightPath(w: w, h: h)
                    // Fixed light-on-dark: the muted theme token resolves
                    // near-black in Light and would disappear on this dark card.
                    .stroke(SteddiTheme.onboardingTextMuted.opacity(0.6),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))

                // The no-go zone: a soft accent-ringed blob. The fill stays the
                // raw hue (contrast carried by the fill); the ring + symbol use
                // the legible accent so they read on the light frost.
                Ellipse()
                    .fill(accentFill.opacity(0.12))
                    .overlay(Ellipse().stroke(glyphAccent.opacity(0.85), lineWidth: 2))
                    .frame(width: blob.width, height: blob.height)
                    .position(x: blob.midX, y: blob.midY)
                    .overlay(
                        Image(systemName: "nosign")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(glyphAccent)
                            .position(x: blob.midX, y: blob.midY)
                    )

                // The chosen route, curving around the blob — drawn on.
                reroutePath(w: w, h: h, blob: blob)
                    .trim(from: 0, to: drawProgress)
                    .stroke(glyphAccent,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

                // The moving tip dot at the head of the drawn line.
                if drawProgress > 0 && drawProgress < 1 {
                    let tip = routeTipPoint(w: w, h: h, blob: blob, at: drawProgress)
                    Circle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .position(x: tip.x, y: tip.y)
                }
            }
        }
    }

    private func straightPath(w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: w * 0.06, y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.94, y: h * 0.5))
        }
    }

    /// A route that curves up and over the no-go blob, then settles back down.
    private func reroutePath(w: CGFloat, h: CGFloat, blob: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: w * 0.06, y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.30, y: h * 0.5))
            // Up and over the blob.
            p.addQuadCurve(
                to: CGPoint(x: blob.midX, y: h * 0.12),
                control: CGPoint(x: w * 0.34, y: h * 0.14)
            )
            p.addQuadCurve(
                to: CGPoint(x: w * 0.70, y: h * 0.5),
                control: CGPoint(x: blob.maxX + w * 0.06, y: h * 0.14)
            )
            p.addLine(to: CGPoint(x: w * 0.94, y: h * 0.5))
        }
    }

    /// The current head of the re-route path, for placing the moving tip dot.
    private func routeTipPoint(w: CGFloat, h: CGFloat, blob: CGRect, at t: CGFloat) -> CGPoint {
        let path = reroutePath(w: w, h: h, blob: blob)
        return path.trimmedPath(from: 0, to: max(0.0001, t)).currentPoint ?? .zero
    }
}
