import SwiftUI
import Charts

/// One trend insight: sentiment icon, human-readable message, magnitude
/// badge, and a sparkline of the recent values behind the trend.
struct TrendInsightCard: View {
    let insight: TrendInsight

    /// FILL / decoration hue — the raw semantic color, for the large bold
    /// sentiment glyph, its tint circle, the card stroke, and the sparkline,
    /// where contrast is carried by size/decoration, not small-text legibility.
    private var sentimentColor: Color {
        switch insight.sentiment {
        case .better: return SteddiTheme.sage
        case .worse: return SteddiTheme.warmRed
        case .steady: return SteddiTheme.accent
        }
    }

    /// TEXT color for the small magnitude VALUE drawn on a surface (the 15%-tint
    /// capsule lets the surface through, so this is text-on-surface, not
    /// text-on-fill). Raw sage/warmRed wash out as text in light/grey
    /// (sage 2.30:1, warmRed 1.77:1), so use the surface-adaptive legible
    /// variants per SteddiTheme's text-vs-fill rule. `.steady` already used the
    /// text-safe accent.
    private var sentimentTextColor: Color {
        switch insight.sentiment {
        case .better: return SteddiTheme.sageText
        case .worse: return SteddiTheme.warmRedText
        case .steady: return SteddiTheme.accent
        }
    }

    private var sentimentIcon: String {
        switch insight.sentiment {
        case .better: return "arrow.down.right"
        case .worse: return "arrow.up.right"
        case .steady: return "equal"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: sentimentIcon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(sentimentColor)
                .frame(width: 32, height: 32)
                .background(Circle().fill(sentimentColor.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text(insight.message)
                    .font(SteddiTheme.heading(15))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = insight.detail {
                    Text(detail)
                        .font(SteddiTheme.body(12))
                        .foregroundStyle(SteddiTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if insight.magnitudeMinutes >= 0.5 {
                    magnitudeBadge
                }
                if insight.sparkline.count >= 3 {
                    sparkline
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                .fill(SteddiTheme.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                        .stroke(sentimentColor.opacity(0.18), lineWidth: 1)
                )
        }
    }

    private var magnitudeBadge: some View {
        Text(badgeText)
            .font(SteddiTheme.mono(12))
            // Value text on a 15%-tint (text-on-surface) capsule → the legible
            // surface-adaptive variant, not the raw hue (washes out in light/grey).
            .foregroundStyle(sentimentTextColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(sentimentColor.opacity(0.15)))
    }

    private var badgeText: String {
        let sign = insight.sentiment == .worse ? "+" : "−"
        return "\(sign)\(Int(insight.magnitudeMinutes.rounded())) min"
    }

    private var sparkline: some View {
        Chart(Array(insight.sparkline.enumerated()), id: \.offset) { index, value in
            LineMark(
                x: .value("Index", index),
                y: .value("Minutes", value)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(sentimentColor)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: sparklineDomain)
        .frame(width: 56, height: 22)
    }

    /// Pad the y-domain so flat sparklines render as a centered line
    /// instead of hugging an edge.
    private var sparklineDomain: ClosedRange<Double> {
        let lo = insight.sparkline.min() ?? 0
        let hi = insight.sparkline.max() ?? 1
        let pad = max((hi - lo) * 0.2, 1)
        return (lo - pad)...(hi + pad)
    }
}

#Preview {
    ZStack {
        SteddiTheme.surfacePrimary.ignoresSafeArea()
        VStack(spacing: 12) {
            TrendInsightCard(insight: TrendInsight(
                id: "weekday-3",
                message: "Tuesday drives are 8 min slower",
                detail: "Compared with your earlier Tuesday drives in this period",
                sentiment: .worse,
                magnitudeMinutes: 8,
                sparkline: [30, 31, 29, 33, 36, 38, 37]
            ))
            TrendInsightCard(insight: TrendInsight(
                id: "overall-steady",
                message: "Your commute is steady",
                detail: "No significant change across 24 drives",
                sentiment: .steady,
                magnitudeMinutes: 0,
                sparkline: [30, 31, 30, 29, 31, 30]
            ))
        }
        .padding()
    }
}
