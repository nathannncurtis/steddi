import Foundation
import SwiftData

/// Logs each completed commute trip for pattern learning.
/// Lightweight — just direction, day, and time. Accumulates over time
/// so the app can learn "you go to work at 7am on weekdays."
@Model
final class CommuteTrip {
    var id: UUID
    var commute: Commute?
    var direction: CommuteDirection
    var dayOfWeek: Int       // 1 = Sunday, 7 = Saturday (Calendar component)
    var hourOfDay: Int       // 0-23
    var timestamp: Date

    init(commute: Commute, direction: CommuteDirection) {
        self.id = UUID()
        self.commute = commute
        self.direction = direction
        self.timestamp = Date()
        // Clamp to expected ranges (dayOfWeek 1-7, hourOfDay 0-23) so downstream
        // arithmetic (e.g. CommuteDirectionResolver hour-distance) and any
        // weekday-indexed array access can never receive an out-of-range value,
        // even if Calendar behaves unexpectedly or stored data is corrupted.
        let cal = Calendar.current
        self.dayOfWeek = min(7, max(1, cal.component(.weekday, from: Date())))
        self.hourOfDay = min(23, max(0, cal.component(.hour, from: Date())))
    }
}
