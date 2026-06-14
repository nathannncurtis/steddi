import MapKit
import UIKit
import SwiftUI

/// Map annotation for a single remembered road condition. Carries enough to
/// render a colored, icon-bearing badge and a preview callout (type, age, note)
/// without holding the SwiftData model on the map layer.
final class RoadConditionAnnotation: NSObject, MKAnnotation {
    let id: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let kind: RoadConditionKind
    let createdAt: Date
    let note: String?

    init(id: UUID, coordinate: CLLocationCoordinate2D, kind: RoadConditionKind, createdAt: Date, note: String?) {
        self.id = id
        self.coordinate = coordinate
        self.kind = kind
        self.createdAt = createdAt
        self.note = note
        super.init()
    }

    convenience init(condition: RoadCondition) {
        self.init(
            id: condition.id,
            coordinate: condition.coordinate,
            kind: condition.kind,
            createdAt: condition.createdAt,
            note: condition.note
        )
    }

    var title: String? { kind.displayName }

    /// Callout subtitle: days since report, then the optional note.
    var subtitle: String? {
        let days = Int(Date().timeIntervalSince(createdAt) / 86_400)
        let age: String
        switch days {
        case ..<1: age = "Reported today"
        case 1: age = "1 day ago"
        default: age = "\(days) days ago"
        }
        if let note, !note.isEmpty { return "\(age) · \(note)" }
        return age
    }
}

/// Marker view for a road-condition badge. Tinted to the kind's color with its
/// SF Symbol glyph. Marker clustering groups nearby badges automatically (MapKit
/// renders the count, e.g. "3"), keeping dense areas legible.
final class RoadConditionMarkerView: MKMarkerAnnotationView {
    static let reuseIdentifier = "RoadConditionMarker"
    /// Shared clustering id so multiple condition badges in a tight area collapse
    /// into one count bubble at low zoom.
    static let clusteringIdentifier = "RoadConditionCluster"

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    private func configure() {
        guard let condition = annotation as? RoadConditionAnnotation else { return }
        clusteringIdentifier = Self.clusteringIdentifier
        canShowCallout = true
        glyphImage = UIImage(systemName: condition.kind.icon)
        markerTintColor = UIColor(condition.kind.color)
        displayPriority = .defaultLow  // yields to the nav puck when crowded
    }
}
