import SwiftUI

/// Start/end hour range selector for zone time windows. Hours are 0...23 for
/// the start and 1...24 for the end (end is exclusive), matching
/// `TimeWindow.startHour` / `TimeWindow.endHour`. A wrapping window (end <=
/// start) is annotated so the user understands it spans midnight.
struct HourRangePicker: View {
    @Binding var start: Int
    @Binding var end: Int

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("From")
                    .font(SteddiTheme.body(14))
                    .foregroundStyle(SteddiTheme.textSecondary)
                Spacer()
                Picker("Start", selection: $start) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .pickerStyle(.menu)
                .tint(SteddiTheme.accent)
            }

            HStack {
                Text("Until")
                    .font(SteddiTheme.body(14))
                    .foregroundStyle(SteddiTheme.textSecondary)
                Spacer()
                Picker("End", selection: $end) {
                    ForEach(1..<25, id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .pickerStyle(.menu)
                .tint(SteddiTheme.accent)
            }

            if end <= start {
                Text("Spans midnight into the next morning")
                    .font(SteddiTheme.body(12))
                    .foregroundStyle(SteddiTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 12-hour clock label for an hour 0...24 (24 shown as midnight).
    static func hourLabel(_ hour: Int) -> String {
        let h = hour % 24
        switch h {
        case 0: return "12 AM"
        case 12: return "12 PM"
        case 1...11: return "\(h) AM"
        default: return "\(h - 12) PM"
        }
    }
}
