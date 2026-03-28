import Foundation
import CoreLocation
import MapKit

/// Generates turn-by-turn navigation steps from a raw polyline.
/// Used for saved/preferred routes where Apple Maps routing is bypassed entirely.
final class CustomRouteBuilder {

    struct CustomStep {
        let instruction: String
        let distance: Double // meters
        let coordinate: CLLocationCoordinate2D // start of this step
        let polylineCoords: [CLLocationCoordinate2D] // coords for this segment
    }

    /// Build navigation steps by analyzing bearing changes along a polyline.
    /// Groups consecutive segments with similar bearings into steps,
    /// detects turns at significant bearing changes.
    static func buildSteps(from coords: [CLLocationCoordinate2D]) -> [CustomStep] {
        guard coords.count >= 2 else { return [] }

        // Simplify the polyline to reduce noise (keep every Nth point based on density)
        let simplified = simplify(coords, tolerance: 15) // 15 meter tolerance

        guard simplified.count >= 2 else { return [] }

        var steps: [CustomStep] = []
        var segmentStart = 0

        // First step: depart
        let initialBearing = bearing(from: simplified[0], to: simplified[min(1, simplified.count - 1)])
        var currentBearing = initialBearing

        for i in 1..<(simplified.count - 1) {
            let nextBearing = bearing(from: simplified[i], to: simplified[i + 1])
            let turn = angleDifference(from: currentBearing, to: nextBearing)

            // Significant turn detected (> 25 degrees)
            if abs(turn) > 25 {
                // Close the current segment
                let segCoords = Array(simplified[segmentStart...i])
                let segDist = polylineDistance(segCoords)

                if segDist > 10 { // ignore tiny segments
                    let instruction: String
                    if steps.isEmpty {
                        instruction = "Head \(cardinalDirection(currentBearing))"
                    } else {
                        instruction = "Continue straight"
                    }
                    steps.append(CustomStep(
                        instruction: instruction,
                        distance: segDist,
                        coordinate: simplified[segmentStart],
                        polylineCoords: segCoords
                    ))
                }

                // Start new segment with turn instruction
                segmentStart = i
                let turnInstruction = turnDescription(angleDegrees: turn)
                // Look ahead to get distance of next segment for the turn step
                currentBearing = nextBearing
                // The turn instruction will be added as the NEXT step's prefix
                // For now, add a turn step at this point
                steps.append(CustomStep(
                    instruction: turnInstruction,
                    distance: 0, // turn point, distance calculated when next segment closes
                    coordinate: simplified[i],
                    polylineCoords: [simplified[i]]
                ))
            }

            currentBearing = nextBearing
        }

        // Close final segment
        let finalCoords = Array(simplified[segmentStart..<simplified.count])
        let finalDist = polylineDistance(finalCoords)
        if finalDist > 10 {
            let instruction = steps.isEmpty ? "Head \(cardinalDirection(currentBearing))" : "Continue straight"
            steps.append(CustomStep(
                instruction: instruction,
                distance: finalDist,
                coordinate: simplified[segmentStart],
                polylineCoords: finalCoords
            ))
        }

        // Add arrival step
        if let last = simplified.last {
            steps.append(CustomStep(
                instruction: "Arrive at your destination",
                distance: 0,
                coordinate: last,
                polylineCoords: [last]
            ))
        }

        // Merge very short "continue straight" steps into adjacent turns
        return mergeShortSteps(steps)
    }

    // MARK: - Turn Detection

    /// Signed angle difference: positive = right turn, negative = left turn
    private static func angleDifference(from a: Double, to b: Double) -> Double {
        var diff = b - a
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return diff
    }

    private static func turnDescription(angleDegrees: Double) -> String {
        let abs = Swift.abs(angleDegrees)
        let side = angleDegrees > 0 ? "right" : "left"

        if abs > 160 { return "Make a U-turn" }
        if abs > 110 { return "Turn sharp \(side)" }
        if abs > 45 { return "Turn \(side)" }
        return "Bear \(side)"
    }

    private static func cardinalDirection(_ degrees: Double) -> String {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        switch normalized {
        case 337.5..<360, 0..<22.5: return "north"
        case 22.5..<67.5: return "northeast"
        case 67.5..<112.5: return "east"
        case 112.5..<157.5: return "southeast"
        case 157.5..<202.5: return "south"
        case 202.5..<247.5: return "southwest"
        case 247.5..<292.5: return "west"
        case 292.5..<337.5: return "northwest"
        default: return "north"
        }
    }

    // MARK: - Geometry

    /// Bearing in degrees from one coordinate to another
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var brng = atan2(y, x) * 180 / .pi
        if brng < 0 { brng += 360 }
        return brng
    }

    /// Total distance along a polyline in meters
    private static func polylineDistance(_ coords: [CLLocationCoordinate2D]) -> Double {
        var dist: Double = 0
        for i in 0..<(coords.count - 1) {
            dist += NavigationEngine.haversineDistance(from: coords[i], to: coords[i + 1])
        }
        return dist
    }

    // MARK: - Simplification

    /// Ramer-Douglas-Peucker polyline simplification
    private static func simplify(_ coords: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }

        var maxDist: Double = 0
        var maxIndex = 0

        let start = coords.first!
        let end = coords.last!

        for i in 1..<(coords.count - 1) {
            let d = perpendicularDistanceMeters(point: coords[i], lineStart: start, lineEnd: end)
            if d > maxDist {
                maxDist = d
                maxIndex = i
            }
        }

        if maxDist > tolerance {
            let left = simplify(Array(coords[0...maxIndex]), tolerance: tolerance)
            let right = simplify(Array(coords[maxIndex...]), tolerance: tolerance)
            return Array(left.dropLast()) + right
        } else {
            return [start, end]
        }
    }

    private static func perpendicularDistanceMeters(
        point: CLLocationCoordinate2D,
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D
    ) -> Double {
        let cosLat = cos(point.latitude * .pi / 180)
        let px = (point.longitude - lineStart.longitude) * cosLat
        let py = point.latitude - lineStart.latitude
        let dx = (lineEnd.longitude - lineStart.longitude) * cosLat
        let dy = lineEnd.latitude - lineStart.latitude

        let segLenSq = dx * dx + dy * dy
        var t: Double = 0
        if segLenSq > 0 {
            t = max(0, min(1, ((px * dx) + (py * dy)) / segLenSq))
        }

        let projLat = lineStart.latitude + t * (lineEnd.latitude - lineStart.latitude)
        let projLon = lineStart.longitude + t * (lineEnd.longitude - lineStart.longitude)
        return NavigationEngine.haversineDistance(
            from: point,
            to: CLLocationCoordinate2D(latitude: projLat, longitude: projLon)
        )
    }

    // MARK: - Step Merging

    /// Merge very short "continue straight" segments into the preceding turn
    private static func mergeShortSteps(_ steps: [CustomStep]) -> [CustomStep] {
        guard steps.count > 1 else { return steps }
        var merged: [CustomStep] = []

        for step in steps {
            if step.distance < 30 && step.instruction == "Continue straight" && !merged.isEmpty {
                // Absorb into previous step
                var prev = merged.removeLast()
                prev = CustomStep(
                    instruction: prev.instruction,
                    distance: prev.distance + step.distance,
                    coordinate: prev.coordinate,
                    polylineCoords: prev.polylineCoords + step.polylineCoords
                )
                merged.append(prev)
            } else {
                merged.append(step)
            }
        }

        return merged
    }
}
