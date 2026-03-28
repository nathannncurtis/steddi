import Foundation
import CoreLocation

/// Generates turn-by-turn NavSteps from a raw polyline.
/// Used for saved/preferred routes where Apple Maps routing is bypassed entirely.
/// Pure Swift + CoreLocation. No MapKit.
final class CustomRouteBuilder {

    /// Build navigation steps by analyzing bearing changes along a polyline.
    static func buildSteps(from coords: [CLLocationCoordinate2D]) -> [NavStep] {
        guard coords.count >= 2 else { return [] }

        let simplified = simplify(coords, tolerance: 15)
        guard simplified.count >= 2 else { return [] }

        var steps: [NavStep] = []
        var segmentStart = 0
        var currentBearing = bearing(from: simplified[0], to: simplified[min(1, simplified.count - 1)])

        for i in 1..<(simplified.count - 1) {
            let nextBearing = bearing(from: simplified[i], to: simplified[i + 1])
            let turn = angleDifference(from: currentBearing, to: nextBearing)

            if abs(turn) > 25 {
                let segCoords = Array(simplified[segmentStart...i])
                let segDist = polylineDistance(segCoords)

                if segDist > 10 {
                    let instr = steps.isEmpty ? "Head \(cardinalDirection(currentBearing))" : "Continue straight"
                    steps.append(NavStep(
                        instruction: instr,
                        distance: segDist,
                        coordinate: simplified[segmentStart],
                        maneuverSymbol: steps.isEmpty ? "location.fill" : "arrow.up"
                    ))
                }

                segmentStart = i
                let turnInstr = turnDescription(angleDegrees: turn)
                let turnSymbol = NavigationEngine.sfSymbolFromInstruction(turnInstr)
                steps.append(NavStep(
                    instruction: turnInstr,
                    distance: 0,
                    coordinate: simplified[i],
                    maneuverSymbol: turnSymbol
                ))

                currentBearing = nextBearing
            }

            currentBearing = nextBearing
        }

        // Final segment
        let finalCoords = Array(simplified[segmentStart..<simplified.count])
        let finalDist = polylineDistance(finalCoords)
        if finalDist > 10 {
            let instr = steps.isEmpty ? "Head \(cardinalDirection(currentBearing))" : "Continue straight"
            steps.append(NavStep(
                instruction: instr,
                distance: finalDist,
                coordinate: simplified[segmentStart],
                maneuverSymbol: steps.isEmpty ? "location.fill" : "arrow.up"
            ))
        }

        // Arrival
        if let last = simplified.last {
            steps.append(NavStep(
                instruction: "Arrive at your destination",
                distance: 0,
                coordinate: last,
                maneuverSymbol: "flag.fill"
            ))
        }

        return mergeShortSteps(steps)
    }

    // MARK: - Turn Detection

    private static func angleDifference(from a: Double, to b: Double) -> Double {
        var diff = b - a
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return diff
    }

    private static func turnDescription(angleDegrees: Double) -> String {
        let a = Swift.abs(angleDegrees)
        let side = angleDegrees > 0 ? "right" : "left"
        if a > 160 { return "Make a U-turn" }
        if a > 110 { return "Turn sharp \(side)" }
        if a > 45 { return "Turn \(side)" }
        return "Bear \(side)"
    }

    private static func cardinalDirection(_ degrees: Double) -> String {
        let n = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        switch n {
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

    private static func polylineDistance(_ coords: [CLLocationCoordinate2D]) -> Double {
        NavigationEngine.polylineDistance(coords)
    }

    // MARK: - Simplification (Ramer-Douglas-Peucker)

    private static func simplify(_ coords: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }
        var maxDist: Double = 0
        var maxIndex = 0
        let start = coords.first!
        let end = coords.last!

        for i in 1..<(coords.count - 1) {
            let d = perpDistMeters(point: coords[i], lineStart: start, lineEnd: end)
            if d > maxDist { maxDist = d; maxIndex = i }
        }

        if maxDist > tolerance {
            let left = simplify(Array(coords[0...maxIndex]), tolerance: tolerance)
            let right = simplify(Array(coords[maxIndex...]), tolerance: tolerance)
            return Array(left.dropLast()) + right
        }
        return [start, end]
    }

    private static func perpDistMeters(point: CLLocationCoordinate2D, lineStart: CLLocationCoordinate2D, lineEnd: CLLocationCoordinate2D) -> Double {
        let cosLat = cos(point.latitude * .pi / 180)
        let px = (point.longitude - lineStart.longitude) * cosLat
        let py = point.latitude - lineStart.latitude
        let dx = (lineEnd.longitude - lineStart.longitude) * cosLat
        let dy = lineEnd.latitude - lineStart.latitude
        let segLenSq = dx * dx + dy * dy
        var t: Double = 0
        if segLenSq > 0 { t = max(0, min(1, ((px * dx) + (py * dy)) / segLenSq)) }
        let projLat = lineStart.latitude + t * (lineEnd.latitude - lineStart.latitude)
        let projLon = lineStart.longitude + t * (lineEnd.longitude - lineStart.longitude)
        return NavigationEngine.haversineDistance(from: point, to: CLLocationCoordinate2D(latitude: projLat, longitude: projLon))
    }

    // MARK: - Merge tiny steps

    private static func mergeShortSteps(_ steps: [NavStep]) -> [NavStep] {
        guard steps.count > 1 else { return steps }
        var merged: [NavStep] = []
        for step in steps {
            if step.distance < 30 && step.instruction == "Continue straight" && !merged.isEmpty {
                var prev = merged.removeLast()
                prev = NavStep(
                    instruction: prev.instruction,
                    distance: prev.distance + step.distance,
                    coordinate: prev.coordinate,
                    maneuverSymbol: prev.maneuverSymbol
                )
                merged.append(prev)
            } else {
                merged.append(step)
            }
        }
        return merged
    }
}
