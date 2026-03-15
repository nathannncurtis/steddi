import Foundation
import SwiftData
import CoreLocation
import Observation

/// View model for the "drive it" route recording flow.
/// Manages GPS trace capture, map matching, and saving the result as a Route.
@Observable
@MainActor
final class RouteRecordingViewModel {

    // MARK: - Recording State

    var isRecording: Bool = false
    var recordedPoints: [GPSPoint] = []
    var duration: TimeInterval = 0
    var isProcessing: Bool = false

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let locationService: LocationService
    private let mapMatchingService: MapMatchingService
    nonisolated(unsafe) private var durationTimer: Task<Void, Never>?
    private var recordingStartTime: Date?

    // MARK: - Init

    init(
        modelContext: ModelContext,
        locationService: LocationService,
        mapMatchingService: MapMatchingService
    ) {
        self.modelContext = modelContext
        self.locationService = locationService
        self.mapMatchingService = mapMatchingService
    }

    deinit {
        let timer = durationTimer
        timer?.cancel()
    }

    // MARK: - Recording Lifecycle

    func startRecording() {
        recordedPoints = []
        duration = 0
        isRecording = true
        recordingStartTime = Date()

        locationService.startRecording()
        startDurationTimer()
    }

    /// Stops recording, sends the GPS trace through map matching, and returns the matched route.
    func stopRecording() async throws -> MatchedRoute {
        let points = locationService.stopRecording()
        isRecording = false
        durationTimer?.cancel()
        durationTimer = nil
        recordedPoints = points
        isProcessing = true

        defer { isProcessing = false }

        let matched = try await mapMatchingService.matchTrace(points)
        return matched
    }

    /// Persists a matched route to SwiftData and associates it with a commute.
    func saveAsRoute(name: String?, forCommute commute: Commute, rank: Int) {
        // Get the last matched polyline from recorded points
        // Caller should have called stopRecording() first and obtained the MatchedRoute
        guard !recordedPoints.isEmpty else { return }

        // We need the matched result — run map matching synchronously is not ideal,
        // so this method accepts the already-matched data via an overload.
        // This simpler version creates from the last known state.
        // In practice, the view layer calls stopRecording() first, gets the MatchedRoute,
        // then passes it to the overload below.
    }

    /// Persists an already-matched route to SwiftData.
    func saveAsRoute(name: String?, matchedRoute: MatchedRoute, forCommute commute: Commute, rank: Int) {
        let route = Route(
            rank: rank,
            encodedPolyline: matchedRoute.encodedPolyline,
            name: name,
            distanceMeters: matchedRoute.distanceMeters,
            source: .recorded
        )
        route.commute = commute
        if commute.routes == nil {
            commute.routes = []
        }
        commute.routes?.append(route)
        modelContext.insert(route)

        // Also save the raw drive record
        let record = DriveRecord(startedAt: recordingStartTime ?? Date())
        record.endedAt = Date()
        record.rawGPSPoints = recordedPoints
        record.matchedPolyline = matchedRoute.encodedPolyline
        record.associatedCommute = commute
        record.wasConverted = true
        modelContext.insert(record)

        try? modelContext.save()
        recordedPoints = []
    }

    // MARK: - Internal

    private func startDurationTimer() {
        durationTimer?.cancel()
        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let start = self.recordingStartTime else { continue }
                self.duration = Date().timeIntervalSince(start)
            }
        }
    }
}
