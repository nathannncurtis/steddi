import Foundation
import MapKit
import CoreLocation
import Observation

/// Custom turn-by-turn navigation engine that tracks user position along an MKRoute.
/// Replaces MapboxNavigationCore with pure MapKit/CoreLocation logic.
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
    /// Position snapped to the route polyline for display (puck alignment).
    var snappedCoordinate: CLLocationCoordinate2D?
    var hasArrived: Bool = false

    /// Full route polyline coordinates for map rendering.
    var routePolylineCoordinates: [CLLocationCoordinate2D] = []

    // MARK: - Private State

    private var activeRoute: MKRoute?
    private var steps: [MKRoute.Step] = []

    /// Cumulative distance from route start to the beginning of each step (indexed by step index).
    private var stepStartDistances: [Double] = []

    /// Total route distance in meters.
    private var totalRouteDistance: Double = 0

    /// Original expected travel time from the route, used for proportional ETA.
    private var originalExpectedTravelTime: TimeInterval = 0

    /// Running average speed in m/s for ETA smoothing.
    private var averageSpeedMPS: Double = 0
    private var speedSampleCount: Int = 0

    // Thresholds
    private let stepTransitionDistance: CLLocationDistance = 30 // meters
    private let arrivalDistance: CLLocationDistance = 50 // meters
    private let offRouteDistance: CLLocationDistance = 50 // meters from route to trigger off-route
    private var offRouteCount: Int = 0 // consecutive off-route GPS updates
    private let offRouteThreshold: Int = 3 // require 3 consecutive off-route readings

    /// Callback for when the user goes off-route and needs rerouting.
    var onOffRoute: ((CLLocationCoordinate2D, CLLocationCoordinate2D) -> Void)? // (currentPosition, destination)

    // MARK: - Start / Stop

    func startNavigation(route: MKRoute) {
        activeRoute = route
        // Filter to steps that have actual instructions; keep all steps for distance tracking
        let allSteps = route.steps
        steps = allSteps.filter { !$0.instructions.isEmpty }
        currentStepIndex = 0
        isNavigating = true
        hasArrived = false
        totalRouteDistance = route.distance
        originalExpectedTravelTime = route.expectedTravelTime
        averageSpeedMPS = 0
        speedSampleCount = 0
        offRouteCount = 0
        routePolylineCoordinates = Self.extractCoordinates(from: route.polyline)

        // Precompute cumulative distances to the start of each filtered step
        precomputeStepDistances()
        updateCurrentStep()
    }

    /// Start navigation using Apple's MKRoute for instructions but a saved polyline for the actual path.
    /// This ensures the engine tracks the user along their preferred route, not Apple's suggested one.
    func startNavigation(route: MKRoute, savedPolyline: [CLLocationCoordinate2D]) {
        startNavigation(route: route)

        // Override the route polyline with the saved one
        if savedPolyline.count >= 2 {
            routePolylineCoordinates = savedPolyline

            // Recalculate total distance based on saved polyline
            var dist: Double = 0
            for i in 0..<(savedPolyline.count - 1) {
                dist += Self.haversineDistance(from: savedPolyline[i], to: savedPolyline[i + 1])
            }
            totalRouteDistance = dist
        }
    }

    func stopNavigation() {
        VoiceGuidanceService.shared.stop()
        isNavigating = false
        activeRoute = nil
        steps = []
        stepStartDistances = []
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
        hasArrived = false
        routePolylineCoordinates = []
        totalRouteDistance = 0
        originalExpectedTravelTime = 0
        averageSpeedMPS = 0
        speedSampleCount = 0
    }

    // MARK: - Location Updates

    /// Called on each GPS update from LocationService.
    func updateLocation(_ location: CLLocation) {
        guard isNavigating, activeRoute != nil, !steps.isEmpty else { return }

        currentCoordinate = location.coordinate

        // Snap position to route polyline for puck alignment
        if !routePolylineCoordinates.isEmpty {
            snappedCoordinate = Self.snapToPolyline(point: location.coordinate, polyline: routePolylineCoordinates)
        } else {
            snappedCoordinate = location.coordinate
        }

        // Use route-based bearing when available for stability, GPS course as fallback
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

        // Update running average speed (only when actually moving)
        if speedMPS > 1.0 {
            speedSampleCount += 1
            averageSpeedMPS += (speedMPS - averageSpeedMPS) / Double(speedSampleCount)
        }

        // Check arrival at destination
        if checkArrival(location: location) { return }

        // Check if user has gone off-route
        if checkOffRoute(location: location) { return }

        // Reset off-route counter when on-route
        offRouteCount = 0

        // Detect step transitions
        advanceStepIfNeeded(location: location)

        // Calculate distances and ETA
        updateDistancesAndETA(location: location)
    }

    // MARK: - Step Management

    private func precomputeStepDistances() {
        stepStartDistances = []
        var cumulative: Double = 0
        for (index, step) in steps.enumerated() {
            stepStartDistances.append(cumulative)
            if index < steps.count - 1 {
                cumulative += step.distance
            }
        }
    }

    private func updateCurrentStep() {
        guard currentStepIndex < steps.count else { return }

        let step = steps[currentStepIndex]
        instruction = step.instructions
        stepDistanceRaw = step.distance
        stepDistance = Self.formatDistance(step.distance)
        maneuverType = Self.sfSymbolFromInstruction(step.instructions)
        roadName = Self.extractRoadName(from: step.instructions)

        // Speak the instruction
        if !step.instructions.isEmpty {
            VoiceGuidanceService.shared.speakWithDistance(step.instructions, distance: step.distance)
        }

        // Estimate speed limit from road type
        speedLimitMph = Self.estimateSpeedLimit(from: step.instructions)

        // Follow-on step
        let nextIndex = currentStepIndex + 1
        if nextIndex < steps.count {
            let nextStep = steps[nextIndex]
            followOnInstruction = nextStep.instructions
            followOnManeuverSymbol = Self.sfSymbolFromInstruction(nextStep.instructions)
        } else {
            followOnInstruction = ""
            followOnManeuverSymbol = ""
        }
    }

    private func advanceStepIfNeeded(location: CLLocation) {
        let nextIndex = currentStepIndex + 1
        guard nextIndex < steps.count else { return }

        let nextStep = steps[nextIndex]
        let nextStepCoords = Self.extractCoordinates(from: nextStep.polyline)
        guard let nextStepStart = nextStepCoords.first else { return }

        let nextStepStartLocation = CLLocation(latitude: nextStepStart.latitude, longitude: nextStepStart.longitude)
        let distanceToNextStep = location.distance(from: nextStepStartLocation)

        if distanceToNextStep < stepTransitionDistance {
            currentStepIndex = nextIndex
            updateCurrentStep()
            HapticService.shared.fire(.turnApproaching)
        }
    }

    private func checkOffRoute(location: CLLocation) -> Bool {
        guard !routePolylineCoordinates.isEmpty else { return false }

        // Find perpendicular distance from user to nearest point on route
        let projection = Self.distanceFromPointToNearestSegment(
            point: location.coordinate,
            polyline: routePolylineCoordinates
        )

        if projection.perpendicularDistance > offRouteDistance {
            offRouteCount += 1
            if offRouteCount >= offRouteThreshold {
                // User is confirmed off-route
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

    // MARK: - Distance & ETA

    private func updateDistancesAndETA(location: CLLocation) {
        guard currentStepIndex < steps.count else { return }

        let currentStep = steps[currentStepIndex]

        // Distance from user to end of current step
        let currentStepCoords = Self.extractCoordinates(from: currentStep.polyline)
        let distAlongCurrentStep = Self.distanceFromPointToNearestSegment(
            point: location.coordinate,
            polyline: currentStepCoords
        )
        let remainingInCurrentStep = max(0, currentStep.distance - distAlongCurrentStep.distanceAlongPolyline)

        // Sum remaining steps' distances
        var totalRemaining = remainingInCurrentStep
        for i in (currentStepIndex + 1)..<steps.count {
            totalRemaining += steps[i].distance
        }

        // Update step distance (remaining in current step)
        stepDistanceRaw = remainingInCurrentStep
        stepDistance = Self.formatDistance(remainingInCurrentStep)

        // Update total distance remaining
        distanceRemaining = Self.formatDistance(totalRemaining)

        // ETA calculation
        let etaSeconds: TimeInterval
        if averageSpeedMPS > 2.0 {
            // Use actual average speed when we have reliable data
            etaSeconds = totalRemaining / averageSpeedMPS
        } else if totalRouteDistance > 0 {
            // Proportional estimate from original route
            let fraction = totalRemaining / totalRouteDistance
            etaSeconds = originalExpectedTravelTime * fraction
        } else {
            etaSeconds = 0
        }

        etaMinutes = max(1, Int(ceil(etaSeconds / 60)))
        arrivalTime = Self.formatArrivalTime(etaSeconds)
    }

    // MARK: - Geometry Helpers

    /// Result of projecting a point onto a polyline.
    private struct ProjectionResult {
        /// Distance from the start of the polyline to the projected point, measured along the polyline.
        let distanceAlongPolyline: Double
        /// Perpendicular distance from the original point to its projection on the polyline.
        let perpendicularDistance: Double
    }

    /// Finds the closest point on a polyline to a given coordinate and returns
    /// both the perpendicular distance and the distance along the polyline.
    private nonisolated static func distanceFromPointToNearestSegment(
        point: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> ProjectionResult {
        guard polyline.count >= 2 else {
            if let first = polyline.first {
                let dist = Self.haversineDistance(from: point, to: first)
                return ProjectionResult(distanceAlongPolyline: 0, perpendicularDistance: dist)
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

    /// Returns (perpendicular distance, clamped t parameter) for a point projected onto a segment.
    private nonisolated static func perpendicularDistance(
        point: CLLocationCoordinate2D,
        segStart: CLLocationCoordinate2D,
        segEnd: CLLocationCoordinate2D
    ) -> (distance: Double, t: Double) {
        // Use flat-earth approximation (accurate enough at navigation scales)
        let cosLat = cos(point.latitude * .pi / 180)
        let px = (point.longitude - segStart.longitude) * cosLat
        let py = point.latitude - segStart.latitude
        let dx = (segEnd.longitude - segStart.longitude) * cosLat
        let dy = segEnd.latitude - segStart.latitude

        let segLenSq = dx * dx + dy * dy
        var t: Double = 0
        if segLenSq > 0 {
            t = ((px * dx) + (py * dy)) / segLenSq
            t = max(0, min(1, t))
        }

        let projLon = segStart.longitude + t * (segEnd.longitude - segStart.longitude)
        let projLat = segStart.latitude + t * (segEnd.latitude - segStart.latitude)
        let projCoord = CLLocationCoordinate2D(latitude: projLat, longitude: projLon)

        let dist = haversineDistance(from: point, to: projCoord)
        return (dist, t)
    }

    /// Haversine distance between two coordinates in meters.
    nonisolated static func haversineDistance(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let R = 6_371_000.0 // Earth radius in meters
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180

        let sinDLat = sin(dLat / 2)
        let sinDLon = sin(dLon / 2)
        let h = sinDLat * sinDLat + cos(lat1) * cos(lat2) * sinDLon * sinDLon
        return 2 * R * asin(sqrt(h))
    }

    // MARK: - Polyline Extraction

    nonisolated static func extractCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    // MARK: - Formatting

    nonisolated static func formatDistance(_ meters: Double) -> String {
        if meters < 160 { // ~500 ft
            return "\(Int(meters * 3.281)) ft"
        }
        let miles = meters / 1609.34
        if miles < 10 {
            return String(format: "%.1f mi", miles)
        }
        return "\(Int(miles)) mi"
    }

    nonisolated static func formatArrivalTime(_ secondsRemaining: TimeInterval) -> String {
        let arrival = Date().addingTimeInterval(secondsRemaining)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: arrival)
    }

    // MARK: - Maneuver Symbol from Instruction Text

    nonisolated static func sfSymbolFromInstruction(_ instruction: String) -> String {
        let lower = instruction.lowercased()

        if lower.contains("arrive") || lower.contains("destination") {
            return "flag.fill"
        }
        if lower.contains("depart") || lower.contains("start") {
            return "location.fill"
        }
        if lower.contains("u-turn") || lower.contains("uturn") {
            return "arrow.uturn.down"
        }
        if lower.contains("roundabout") || lower.contains("rotary") {
            return "arrow.triangle.2.circlepath"
        }
        if lower.contains("merge") {
            return "arrow.merge"
        }
        if lower.contains("ramp") {
            if lower.contains("left") {
                return "arrow.up.left"
            }
            return "arrow.up.right"
        }
        if lower.contains("sharp left") {
            return "arrow.turn.up.left"
        }
        if lower.contains("sharp right") {
            return "arrow.turn.up.right"
        }
        if lower.contains("slight left") || lower.contains("bear left") || lower.contains("keep left") {
            return "arrow.turn.up.left"
        }
        if lower.contains("slight right") || lower.contains("bear right") || lower.contains("keep right") {
            return "arrow.turn.up.right"
        }
        if lower.contains("turn left") || lower.hasPrefix("left") {
            return "arrow.turn.up.left"
        }
        if lower.contains("turn right") || lower.hasPrefix("right") {
            return "arrow.turn.up.right"
        }

        return "arrow.up" // continue straight
    }

    // MARK: - Route Snapping

    /// Project a point onto the nearest segment of a polyline, returning the snapped coordinate.
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
            if segLenSq > 0 {
                t = ((px * dx) + (py * dy)) / segLenSq
                t = max(0, min(1, t))
            }

            let projLat = segStart.latitude + t * (segEnd.latitude - segStart.latitude)
            let projLon = segStart.longitude + t * (segEnd.longitude - segStart.longitude)
            let projCoord = CLLocationCoordinate2D(latitude: projLat, longitude: projLon)

            let dist = haversineDistance(from: point, to: projCoord)
            if dist < bestDist {
                bestDist = dist
                bestCoord = projCoord
            }
        }

        return bestCoord
    }

    // MARK: - Route Bearing

    /// Calculate bearing along the route at the closest point to the user's position.
    /// Gives a stable, route-following heading instead of noisy GPS course.
    nonisolated static func bearingAlongRoute(from position: CLLocationCoordinate2D, routeCoords: [CLLocationCoordinate2D]) -> Double {
        guard routeCoords.count >= 2 else { return 0 }

        var bestIndex = 0
        var bestDist = Double.greatestFiniteMagnitude

        for i in 0..<routeCoords.count {
            let d = haversineDistance(from: position, to: routeCoords[i])
            if d < bestDist {
                bestDist = d
                bestIndex = i
            }
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

    // MARK: - Speed Limit Estimation

    /// Estimate speed limit from instruction text and road name patterns.
    /// Uses heuristics since MapKit doesn't provide speed limit data.
    nonisolated static func estimateSpeedLimit(from instruction: String) -> Double {
        let lower = instruction.lowercased()

        // Freeway/highway indicators
        if lower.contains("i-") || lower.contains("interstate") ||
           lower.contains("freeway") || lower.contains("motorway") ||
           lower.contains("us-") || lower.contains("highway") {
            return 65
        }

        // State routes and expressways
        if lower.contains("sr-") || lower.contains("state route") ||
           lower.contains("expressway") || lower.contains("pkwy") ||
           lower.contains("parkway") || lower.contains("blvd") ||
           lower.contains("boulevard") {
            return 45
        }

        // Ramps
        if lower.contains("ramp") || lower.contains("merge") {
            return 40
        }

        // Common residential/urban patterns
        if lower.contains("ave") || lower.contains("avenue") ||
           lower.contains("st ") || lower.contains("street") ||
           lower.contains("rd ") || lower.contains("road") ||
           lower.contains("dr ") || lower.contains("drive") ||
           lower.contains("ln ") || lower.contains("lane") ||
           lower.contains("ct ") || lower.contains("court") {
            return 35
        }

        // Default for unknown roads
        return 45
    }

    // MARK: - Road Name Extraction

    nonisolated static func extractRoadName(from instruction: String) -> String {
        // Look for "onto <road name>" pattern
        if let ontoRange = instruction.range(of: "onto ", options: .caseInsensitive) {
            let roadName = String(instruction[ontoRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !roadName.isEmpty {
                return roadName
            }
        }
        // Look for "on <road name>" pattern (less common)
        if let onRange = instruction.range(of: " on ", options: .caseInsensitive) {
            let roadName = String(instruction[onRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !roadName.isEmpty {
                return roadName
            }
        }
        return ""
    }
}
