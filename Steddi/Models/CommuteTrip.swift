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
        let cal = Calendar.current
        self.dayOfWeek = cal.component(.weekday, from: Date())
        self.hourOfDay = cal.component(.hour, from: Date())
    }
}
