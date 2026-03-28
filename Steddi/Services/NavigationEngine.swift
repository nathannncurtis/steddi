import Foundation
import MapKit
import CoreLocation
import Observation

/// A single navigation step — Steddi's own type, independent of MKRoute.Step.
struct NavStep {
    let instruction: String
    let distance: Double // meters
    let coordinate: CLLocationCoordinate2D // where this step begins
    let maneuverSymbol: String
}

/// Pure custom navigation engine. Works entirely from coordinates and steps.
/// MKRoute is just an input adapter — the engine never touches Apple routing internals.
@Observable
@MainActor
final class NavigationEngine {

    // MARK: - Public State

    var isNavigating: Bool = false
    var currentStepIndex: Int = 0
    var instruction: String = ""
    var stepDistance: String = ""
    var stepDistanceRaw: Double = 0
    var etaMinutes: Int = 0
    var distanceRemaining: String = ""
    var arrivalTime: String = ""
    var roadName: String = ""
    var maneuverType: String = "arrow.up"
    var followOnInstruction: String = ""
    var followOnManeuverSymbol: String = ""
    var currentSpeedMph: Double = 0
    var speedLimitMph: Double? = nil
    var headingDegrees: Double = 0
    var currentCoordinate: CLLocationCoordinate2D?
    var snappedCoordinate: CLLocationCoordinate2D?
    var hasArrived: Bool = false

    /// Full route polyline for map rendering and position tracking.
    var routePolylineCoordinates: [CLLocationCoordinate2D] = []

    // MARK: - Private State

    private var steps: [NavStep] = []
    private var totalRouteDistance: Double = 0
    private var originalExpectedTravelTime: TimeInterval = 0
    private var averageSpeedMPS: Double = 0
    private var speedSampleCount: Int = 0
    private var locationUpdateCount: Int = 0

    // Thresholds
    private let stepTransitionDistance: CLLocationDistance = 40
    private let arrivalDistance: CLLocationDistance = 50
    private let offRouteDistance: CLLocationDistance = 80
    private var offRouteCount: Int = 0
    private let offRouteThreshold: Int = 5
    private let offRouteGracePeriod: Int = 10

    /// Fires when user goes off-route. (currentPosition, destination)
    var onOffRoute: ((CLLocationCoordinate2D, CLLocationCoordinate2D) -> Void)?

    // MARK: - Start from saved polyline (primary path)

    /// Start navigation from a polyline with custom steps.
    /// This is the core path — everything flows through here.
    func startNavigation(polyline: [CLLocationCoordinate2D], steps: [NavStep]) {
        self.steps = steps
        currentStepIndex = 0
        isNavigating = true
        hasArrived = false
        averageSpeedMPS = 0
        speedSampleCount = 0
        offRouteCount = 0
        locationUpdateCount = 0
        routePolylineCoordinates = polyline

        totalRouteDistance = Self.polylineDistance(polyline)
        // Seed ETA: assume ~30 mph average
        originalExpectedTravelTime = totalRouteDistance / 13.4

        if !steps.isEmpty {
            applyStep(at: 0)
        }
    }

    // MARK: - Start from MKRoute (adapter for dumb nav)

    /// Convenience: convert an MKRoute to our format and start navigation.
    /// Apple's data is adapted into NavSteps — the engine doesn't use MKRoute internally.
    func startNavigation(route: MKRoute) {
        let polyline = Self.extractCoordinates(from: route.polyline)
        let navSteps = Self.convertMKRouteToSteps(route)

        startNavigation(polyline: polyline, steps: navSteps)

        // Override with Apple's more accurate values
        totalRouteDistance = route.distance
        originalExpectedTravelTime = route.expectedTravelTime
    }

    func stopNavigation() {
        VoiceGuidanceService.shared.stop()
        isNavigating = false
        steps = []
        currentStepIndex = 0
        instruction = ""
        stepDistance = ""
        stepDistanceRaw = 0
        etaMinutes = 0
        distanceRemaining = ""
        arrivalTime = ""
        roadName = ""
        maneuverType = "arrow.up"
        followOnInstruction = ""
        followOnManeuverSymbol = ""
        currentSpeedMph = 0
        speedLimitMph = nil
        headingDegrees = 0
        currentCoordinate = nil
        snappedCoordinate = nil
        hasArrived = false
        routePolylineCoordinates = []
        totalRouteDistance = 0
        originalExpectedTravelTime = 0
        averageSpeedMPS = 0
        speedSampleCount = 0
        offRouteCount = 0
        locationUpdateCount = 0
    }

    // MARK: - Location Updates

    func updateLocation(_ location: CLLocation) {
        guard isNavigating, !steps.isEmpty else { return }

        currentCoordinate = location.coordinate
        locationUpdateCount += 1

        // Snap to polyline
        if !routePolylineCoordinates.isEmpty {
            snappedCoordinate = Self.snapToPolyline(point: location.coordinate, polyline: routePolylineCoordinates)
        } else {
            snappedCoordinate = location.coordinate
        }

        // Route-based bearing for stability
        if !routePolylineCoordinates.isEmpty {
            let routeBearing = Self.bearingAlongRoute(from: location.coordinate, routeCoords: routePolylineCoordinates)
            if routeBearing > 0 || routePolylineCoordinates.count >= 2 {
                headingDegrees = routeBearing
            }
        } else if location.course >= 0 {
            headingDegrees = location.course
        }

        let speedMPS = max(0, location.speed)
        currentSpeedMph = speedMPS * 2.23694

        if speedMPS > 1.0 {
            speedSampleCount += 1
            averageSpeedMPS += (speedMPS - averageSpeedMPS) / Double(speedSampleCount)
        }

        if checkArrival(location: location) { return }

        if checkOffRoute(location: location) { return }
        offRouteCount = 0

        advanceStepIfNeeded(location: location)
        updateDistancesAndETA(location: location)
    }

    // MARK: - Step Logic

    private func applyStep(at index: Int) {
        guard index < steps.count else { return }

        let step = steps[index]
        instruction = step.instruction
        stepDistanceRaw = step.distance
        stepDistance = Self.formatDistance(step.distance)
        maneuverType = step.maneuverSymbol
        roadName = Self.extractRoadName(from: step.instruction)
        speedLimitMph = Self.estimateSpeedLimit(from: step.instruction)

        if !step.instruction.isEmpty {
            VoiceGuidanceService.shared.speakWithDistance(step.instruction, distance: step.distance)
        }

        let nextIndex = index + 1
        if nextIndex < steps.count {
            followOnInstruction = steps[nextIndex].instruction
            followOnManeuverSymbol = steps[nextIndex].maneuverSymbol
        } else {
            followOnInstruction = ""
            followOnManeuverSymbol = ""
        }
    }

    private func advanceStepIfNeeded(location: CLLocation) {
        let nextIndex = currentStepIndex + 1
        guard nextIndex < steps.count else { return }

        let nextStep = steps[nextIndex]
        let distToNext = Self.haversineDistance(from: location.coordinate, to: nextStep.coordinate)

        if distToNext < stepTransitionDistance {
            currentStepIndex = nextIndex
            applyStep(at: nextIndex)
            HapticService.shared.fire(.turnApproaching)
        }
    }

    private func checkArrival(location: CLLocation) -> Bool {
        guard let lastCoord = routePolylineCoordinates.last else { return false }
        let destination = CLLocation(latitude: lastCoord.latitude, longitude: lastCoord.longitude)
        if location.distance(from: destination) < arrivalDistance {
            hasArrived = true
            HapticService.shared.fire(.arrival)
            VoiceGuidanceService.shared.speakArrival()
            instruction = "You have arrived"
            maneuverType = "flag.fill"
            stepDistance = ""
            stepDistanceRaw = 0
            distanceRemaining = ""
            etaMinutes = 0
            arrivalTime = ""
            followOnInstruction = ""
            followOnManeuverSymbol = ""
            return true
        }
        return false
    }

    private func checkOffRoute(location: CLLocation) -> Bool {
        guard !routePolylineCoordinates.isEmpty else { return false }
        guard locationUpdateCount > offRouteGracePeriod else { return false }

        let projection = Self.distanceFromPointToNearestSegment(
            point: location.coordinate,
            polyline: routePolylineCoordinates
        )

        if projection.perpendicularDistance > offRouteDistance {
            offRouteCount += 1
            if offRouteCount >= offRouteThreshold {
                guard let destination = routePolylineCoordinates.last else { return false }
                onOffRoute?(location.coordinate, destination)
                offRouteCount = 0
                return true
            }
        } else {
            offRouteCount = 0
        }

        return false
    }

    // MARK: - Distance & ETA

    private func updateDistancesAndETA(location: CLLocation) {
        // Project user onto the full route polyline to get distance traveled
        let projection = Self.distanceFromPointToNearestSegment(
            point: location.coordinate,
            polyline: routePolylineCoordinates
        )
        let distanceTraveled = projection.distanceAlongPolyline
        let totalRemaining = max(0, totalRouteDistance - distanceTraveled)

        // Step-level remaining: distance from user to next step's coordinate
        let nextIndex = currentStepIndex + 1
        if nextIndex < steps.count {
            let distToNext = Self.haversineDistance(from: location.coordinate, to: steps[nextIndex].coordinate)
            stepDistanceRaw = distToNext
            stepDistance = Self.formatDistance(distToNext)
        } else {
            // Last step — distance to destination
            if let last = routePolylineCoordinates.last {
                let d = Self.haversineDistance(from: location.coordinate, to: last)
                stepDistanceRaw = d
                stepDistance = Self.formatDistance(d)
            }
        }

        distanceRemaining = Self.formatDistance(totalRemaining)

        let etaSeconds: TimeInterval
        if averageSpeedMPS > 2.0 {
            etaSeconds = totalRemaining / averageSpeedMPS
        } else if totalRouteDistance > 0 {
            let fraction = totalRemaining / totalRouteDistance
            etaSeconds = originalExpectedTravelTime * fraction
        } else {
            etaSeconds = 0
        }

        etaMinutes = max(1, Int(ceil(etaSeconds / 60)))
        arrivalTime = Self.formatArrivalTime(etaSeconds)
    }

    // MARK: - MKRoute Adapter

    /// Convert MKRoute.Steps into NavSteps. This is the only place Apple types are used.
    private static func convertMKRouteToSteps(_ route: MKRoute) -> [NavStep] {
        route.steps
            .filter { !$0.instructions.isEmpty }
            .map { step in
                let coords = extractCoordinates(from: step.polyline)
                return NavStep(
                    instruction: step.instructions,
                    distance: step.distance,
                    coordinate: coords.first ?? step.polyline.coordinate,
                    maneuverSymbol: sfSymbolFromInstruction(step.instructions)
                )
            }
    }

    // MARK: - Geometry

    struct ProjectionResult {
        let distanceAlongPolyline: Double
        let perpendicularDistance: Double
    }

    nonisolated static func distanceFromPointToNearestSegment(
        point: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> ProjectionResult {
        guard polyline.count >= 2 else {
            if let first = polyline.first {
                return ProjectionResult(distanceAlongPolyline: 0, perpendicularDistance: haversineDistance(from: point, to: first))
            }
            return ProjectionResult(distanceAlongPolyline: 0, perpendicularDistance: .greatestFiniteMagnitude)
        }

        var bestPerpDistance = Double.greatestFiniteMagnitude
        var bestAlongDistance: Double = 0
        var cumulativeDistance: Double = 0

        for i in 0..<(polyline.count - 1) {
            let segStart = polyline[i]
            let segEnd = polyline[i + 1]
            let segLength = haversineDistance(from: segStart, to: segEnd)
            let (projDist, t) = perpendicularDistance(point: point, segStart: segStart, segEnd: segEnd)

            if projDist < bestPerpDistance {
                bestPerpDistance = projDist
                bestAlongDistance = cumulativeDistance + segLength * t
            }
            cumulativeDistance += segLength
        }

        return ProjectionResult(distanceAlongPolyline: bestAlongDistance, perpendicularDistance: bestPerpDistance)
    }

    private nonisolated static func perpendicularDistance(
        point: CLLocationCoordinate2D,
        segStart: CLLocationCoordinate2D,
        segEnd: CLLocationCoordinate2D
    ) -> (distance: Double, t: Double) {
        let cosLat = cos(point.latitude * .pi / 180)
        let px = (point.longitude - segStart.longitude) * cosLat
        let py = point.latitude - segStart.latitude
        let dx = (segEnd.longitude - segStart.longitude) * cosLat
        let dy = segEnd.latitude - segStart.latitude

        let segLenSq = dx * dx + dy * dy
        var t: Double = 0
        if segLenSq > 0 {
            t = max(0, min(1, ((px * dx) + (py * dy)) / segLenSq))
        }

        let projLat = segStart.latitude + t * (segEnd.latitude - segStart.latitude)
        let projLon = segStart.longitude + t * (segEnd.longitude - segStart.longitude)
        return (haversineDistance(from: point, to: CLLocationCoordinate2D(latitude: projLat, longitude: projLon)), t)
    }

    nonisolated static func haversineDistance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinDLat = sin(dLat / 2)
        let sinDLon = sin(dLon / 2)
        let h = sinDLat * sinDLat + cos(lat1) * cos(lat2) * sinDLon * sinDLon
        return 2 * R * asin(sqrt(h))
    }

    nonisolated static func snapToPolyline(point: CLLocationCoordinate2D, polyline: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard polyline.count >= 2 else { return polyline.first ?? point }
        var bestDist = Double.greatestFiniteMagnitude
        var bestCoord = point
        let cosLat = cos(point.latitude * .pi / 180)

        for i in 0..<(polyline.count - 1) {
            let segStart = polyline[i]
            let segEnd = polyline[i + 1]
            let px = (point.longitude - segStart.longitude) * cosLat
            let py = point.latitude - segStart.latitude
            let dx = (segEnd.longitude - segStart.longitude) * cosLat
            let dy = segEnd.latitude - segStart.latitude
            let segLenSq = dx * dx + dy * dy
            var t: Double = 0
            if segLenSq > 0 { t = max(0, min(1, ((px * dx) + (py * dy)) / segLenSq)) }
            let projLat = segStart.latitude + t * (segEnd.latitude - segStart.latitude)
            let projLon = segStart.longitude + t * (segEnd.longitude - segStart.longitude)
            let projCoord = CLLocationCoordinate2D(latitude: projLat, longitude: projLon)
            let dist = haversineDistance(from: point, to: projCoord)
            if dist < bestDist { bestDist = dist; bestCoord = projCoord }
        }
        return bestCoord
    }

    nonisolated static func bearingAlongRoute(from position: CLLocationCoordinate2D, routeCoords: [CLLocationCoordinate2D]) -> Double {
        guard routeCoords.count >= 2 else { return 0 }
        var bestIndex = 0
        var bestDist = Double.greatestFiniteMagnitude
        for i in 0..<routeCoords.count {
            let d = haversineDistance(from: position, to: routeCoords[i])
            if d < bestDist { bestDist = d; bestIndex = i }
        }
        let lookAheadIndex = min(bestIndex + 3, routeCoords.count - 1)
        guard lookAheadIndex > bestIndex else { return 0 }
        let from = routeCoords[bestIndex]
        let to = routeCoords[lookAheadIndex]
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return bearing
    }

    nonisolated static func extractCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    nonisolated static func polylineDistance(_ coords: [CLLocationCoordinate2D]) -> Double {
        var dist: Double = 0
        for i in 0..<(coords.count - 1) {
            dist += haversineDistance(from: coords[i], to: coords[i + 1])
        }
        return dist
    }

    // MARK: - Formatting

    nonisolated static func formatDistance(_ meters: Double) -> String {
        if meters < 160 { return "\(Int(meters * 3.281)) ft" }
        let miles = meters / 1609.34
        if miles < 10 { return String(format: "%.1f mi", miles) }
        return "\(Int(miles)) mi"
    }

    nonisolated static func formatArrivalTime(_ secondsRemaining: TimeInterval) -> String {
        let arrival = Date().addingTimeInterval(secondsRemaining)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: arrival)
    }

    // MARK: - Instruction Parsing

    nonisolated static func sfSymbolFromInstruction(_ instruction: String) -> String {
        let lower = instruction.lowercased()
        if lower.contains("arrive") || lower.contains("destination") { return "flag.fill" }
        if lower.contains("depart") || lower.contains("start") || lower.contains("head ") { return "location.fill" }
        if lower.contains("u-turn") || lower.contains("uturn") { return "arrow.uturn.down" }
        if lower.contains("roundabout") || lower.contains("rotary") { return "arrow.triangle.2.circlepath" }
        if lower.contains("merge") { return "arrow.merge" }
        if lower.contains("ramp") && lower.contains("left") { return "arrow.up.left" }
        if lower.contains("ramp") { return "arrow.up.right" }
        if lower.contains("sharp left") { return "arrow.turn.up.left" }
        if lower.contains("sharp right") { return "arrow.turn.up.right" }
        if lower.contains("bear left") || lower.contains("slight left") || lower.contains("keep left") { return "arrow.turn.up.left" }
        if lower.contains("bear right") || lower.contains("slight right") || lower.contains("keep right") { return "arrow.turn.up.right" }
        if lower.contains("turn left") || lower.hasPrefix("left") { return "arrow.turn.up.left" }
        if lower.contains("turn right") || lower.hasPrefix("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }

    nonisolated static func estimateSpeedLimit(from instruction: String) -> Double {
        let lower = instruction.lowercased()
        if lower.contains("i-") || lower.contains("interstate") || lower.contains("freeway") || lower.contains("motorway") || lower.contains("us-") || lower.contains("highway") { return 65 }
        if lower.contains("sr-") || lower.contains("state route") || lower.contains("expressway") || lower.contains("pkwy") || lower.contains("parkway") || lower.contains("blvd") || lower.contains("boulevard") { return 45 }
        if lower.contains("ramp") || lower.contains("merge") { return 40 }
        if lower.contains("ave") || lower.contains("avenue") || lower.contains("st ") || lower.contains("street") || lower.contains("rd ") || lower.contains("road") || lower.contains("dr ") || lower.contains("drive") || lower.contains("ln ") || lower.contains("lane") || lower.contains("ct ") || lower.contains("court") { return 35 }
        return 45
    }

    nonisolated static func extractRoadName(from instruction: String) -> String {
        if let ontoRange = instruction.range(of: "onto ", options: .caseInsensitive) {
            let name = String(instruction[ontoRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        if let onRange = instruction.range(of: " on ", options: .caseInsensitive) {
            let name = String(instruction[onRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return ""
    }
}
