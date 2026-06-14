# Steddi Architecture

## Overview
SwiftUI views bind directly to @Observable services and SwiftData models via @Environment and @Query — there is no separate ViewModel layer. NavigationStateManager is the shared source of truth for navigation state; the phone UI and CarPlay both read from it.

```
Views (SwiftUI)                      CarPlay (UIKit)
  HomeView, SteddiNavOverlay,          CarPlaySceneDelegate (CPMapTemplate)
  RoutePreviewView, SettingsView       CarPlayMapController (MKMapView)
    |                                  CarPlayDashboardDelegate (dashboard widget)
    | @Environment / @Query                |
    v                                      v
Services  <----  NavigationStateManager (shared nav state)
  NavigationEngine*       LocationService*
  RerouteEngine           DirectionsService (MKDirections)
  RouteRecoveryEngine     GeocodingService (MKLocalSearch)
  MapMatchingService      OfflineCacheService*
  CustomRouteBuilder      OSMSpeedLimitService
  VoiceGuidanceService    HapticService
  LiveActivityService     FuzzyRouteParser
  ThemeEngine / DisplayModeService / WeatherKitService
  AudioDuckingService / NowPlayingService
  SpeedCameraService / RoadConditionService
  CommuteNotificationService / AnalyticsService
  ZoneDrawingService / ZoneValidationEngine / TripProgression
  Routing/ (custom router — see below)
  (* = @Observable, as is NavigationStateManager; the
   rest are plain classes/singletons/structs)
    |
    v
Models (SwiftData)
  PinnedLocation, Commute, Route, DriveRecord, NoGoZone, CommuteTrip,
  Report, Trip, TripStop, RoadCondition, CameraReport,
  CommuteAnalyticsAggregate
```

## Navigation Engine
Custom turn-by-turn engine — no navigation SDK. NavigationEngine works entirely from coordinates and its own NavStep model; MKRoute is just an input adapter. Polyline-first: position snapping, step transitions, arrival, and off-route detection (80 m perpendicular distance, 5 consecutive hits) are all computed against the route polyline. CustomRouteBuilder generates NavSteps from raw polyline geometry as a fallback for saved routes that predate stored steps.

NavigationStateManager mirrors engine state on a 500 ms poll, feeds CarPlay, runs a periodic reroute check (every 5 minutes), and writes ETA to the shared App Group for the widget. The Live Activity is not driven by the state manager — HomeView's location-feed loop calls LiveActivityService directly with NavigationEngine state every 6th 500 ms tick (~every 3 seconds).

## Custom Routing Engine
A from-scratch road-graph router lives under `Services/Routing/`, behind a single
`RouteProvider` seam. Both engines — MapKit (`DirectionsService`) and the custom
router (`CustomRouter`) — emit a `GeneratedRoute` (polyline + `NavStep`s +
expected travel time + `RouterEngine` provenance), which adapts to the existing
`DirectionsRoute` so it flows through every existing call site unchanged.

`RouteProviderSelector` chooses the engine per request from a global flag
(`steddi.useCustomRouter`, **default false** — MapKit stays user-facing). When the
flag is on, the custom router is tried first and, on any nil (graph not loaded, no
path, degraded synthesis), the request **automatically falls back to MapKit** for
that one request. MapKit is always the safety net; the custom router never throws
and never strands a drive.

Pipeline (built in phases):
- **RoadGraphSource / RoadGraphBuilder / RoadGraphSerializer** — load a routable
  `RoadGraph` for a commute corridor from OpenStreetMap via Overpass, build a
  compact node/edge graph (edges carry oncoming-lane count and dedicated-left
  flag for turn costs), and cache it on-device (SHA256-keyed disk cache, 30-day
  TTL, expired-but-present cache kept for stale-fallback degradation). Mirrors
  `OSMSpeedLimitService`'s proven Overpass scaffolding (mirror list, 429/5xx
  failover, off-main fetch/decode/build).
- **AStarSearch / BinaryHeap** — A* over the graph with snap-to-graph for
  arbitrary origin/destination coordinates (mid-edge starts/ends recorded as
  fractions for geometry trimming). Heuristic is the pure free-flow time lower
  bound, kept admissible.
- **DefaultCostModel** — pluggable cost model. Generalized turn weighting charged
  at the maneuver node: right turns, protected vs. unprotected lefts (unprotected
  scaled by oncoming-lane count — the "busy left is expensive enough that a right
  detour wins" signal), U-turns, stop signs, traffic signals; per-road-class
  comfort multipliers; no-go zones as soft/hard cost; time-of-day weighting from
  the request's departure date. All multipliers are >= 1 and penalties >= 0 so
  the A* heuristic stays admissible.
- **StepSynthesizer** — turns the solved edge path into a polyline + `NavStep`s in
  the grammar `NavigationEngine`'s symbol and voice classifiers already speak.
- **PreferenceLearner / LearnedWeightsStore** — per-driver weight learning (pure,
  offline, unit-testable). Map-matches the driver's own `DriveRecord` traces onto
  the corridor graph and nudges `CostWeights` toward revealed preference; the
  router reads the most specific learned weights for the request's scope.
- **CorridorValidator** — deterministic regression harness (no network) that runs
  the router over `RoadGraph` fixtures and asserts structural invariants
  (connectedness, monotone progress toward the destination, no wild detours).

Traffic-aware ETA and the reroute decision deliberately stay on
`DirectionsService` regardless of engine — the custom router's travel time is
free-flow, not traffic-aware. Route generation is the only thing abstracted.

Note: `RouterEngine` provenance is carried on the in-memory `GeneratedRoute` for
A-B comparison but is not (yet) persisted on the `Route` SwiftData model — saved
routes record only `RouteSource` (how the route was created), not which engine
produced them.

## Major Subsystems
- **Dynamic theming** — `ThemeEngine` blends layers (solar position × weather ×
  temperature × tunnel) in real time. `WeatherKitService` feeds a reduced
  `WeatherConditionSnapshot`; `LocalNormsProvider` supplies climate-relative
  temperature norms (65°F reads warm in Anchorage, cool in San Diego);
  `TunnelDetectionService` fades to dark on tunnel entry/exit.
- **No-go zones v2** — `ZoneDrawingService` builds zone geometry four ways:
  freehand (OSRM map-matched), dot-to-dot (OSRM via-routing), polygon (verbatim),
  and named road (geocoded corridor). Zones carry an optional `TimeWindow` for
  time-based activation. `ZoneValidationEngine` validates candidate routes against
  active zones with pure geometry.
- **Speed traps / red-light cameras** — `SpeedCameraService` unifies OSM-sourced
  camera nodes (Overpass) and crowdsourced `CameraReport`s into one spatial index
  for quiet proximity alerts; reports are filed from the nav overlay.
- **Road-condition memory** — `RoadConditionService` + `RoadCondition` remember
  potholes/construction per route, with a post-arrival report prompt and
  decay/reconfirm lifecycle.
- **Smart commute notifications** — `CommuteNotificationService` (BackgroundTasks)
  gathers learned departure windows, current ETA vs. typical, and weather, then a
  pure `CommuteNotificationDecisionEngine` decides whether to nudge. Fully
  on-device.
- **Analytics** — `AnalyticsService` aggregates `DriveRecord` history (averages by
  day, time in traffic, trends) into `CommuteAnalyticsView` (Swift Charts).
- **Trips** — third saved-route category. `Trip`/`TripStop` model multi-stop
  routes; `TripProgression` is a pure UUID-based leg state machine; flow is
  continuous (auto-queue next leg on arrival) or manual.
- **Music + ducking** — `NowPlayingService` (remote commands route to whatever app
  owns audio) and `AudioDuckingService` (voice and alert ducking independently
  configurable; ducks media, never pauses).
- **Emergency, passenger/accessibility, onboarding** — `EmergencyView` (share
  location, nearby services, contact, roadside); `DisplayModeService` drives
  independent passenger and accessibility scaling/contrast; the onboarding
  coordinator conveys feel and offers (skippable) emergency-contact setup.

## Reroute Threshold Algorithm

The reroute engine uses a percentage-based threshold evaluated against REMAINING ETA (not original trip duration).

### How it works:
1. **Base percentage**: User sets a sensitivity (default 20%).
2. **Scaling**: The base percentage is scaled by a sigmoid curve centered at 30 minutes remaining:
   - Less than 10 min remaining: threshold ~1.5x base (harder to trigger)
   - ~30 min remaining: threshold = base (unchanged)
   - 60+ min remaining: threshold ~0.7x base (easier to trigger)
   - 90+ min remaining: threshold floors at ~0.5x base
3. **Percentage always wins**: If percentage threshold is met, reroute is suggested regardless of hard minute floor.
4. **Hard minute floor**: Secondary gate for long drives. If percentage is not met but absolute savings exceed the hard floor (default 10 min), suggest anyway.
5. **Re-evaluated continuously**: Every engine run uses current remaining ETA. As you get closer, same absolute savings = higher percentage = more likely to trigger.

## Offline Strategy
- Users can manually download routes for persistent offline access (Documents/, managed from the commute detail view)
- OfflineCacheService also implements an active-navigation cache (route geometry to Caches/, with a 5-minute post-nav cleanup timer), but it is not yet wired into navigation — cacheActiveRoute/scheduleCleanup/loadCachedRoute have no callers, so nothing is cached on nav start and nothing reads cached data back
- Cached payloads (both downloads and the unwired active cache) store route geometry, distance, and typical duration only — turn-by-turn instructions are not cached
- Offline turn-by-turn and traffic data are not available

## MapKit / OSM / OSRM Integration Points
| Feature | API | When Used |
|---------|-----|-----------|
| Map display | MKMapView (phone + CarPlay) | Always |
| Routing & traffic ETAs | MKDirections | Planning, previews, reroute evaluation (default route engine) |
| Place search | MKLocalSearch | Search, fuzzy route parsing |
| Route snapping | OSRM Map Matching (router.project-osrm.org) | After drive-it recording; freehand no-go zones |
| Via-routing | OSRM | Multi-stop / dot-to-dot zone corridors |
| Road graph, speed limits, cameras | Overpass (OpenStreetMap) | Custom router graph, speed-limit corridors, OSM cameras |
| Turn-by-turn | Custom NavigationEngine | Active navigation |
| Route generation (opt-in) | Custom road-graph router (A*) | When `steddi.useCustomRouter` is on; MapKit fallback otherwise |
| Weather | WeatherKit | Dynamic theming, commute notifications |

## Extensions
- SteddiWidget — home screen commute ETA widget (WidgetKit)
- SteddiLiveActivity — Dynamic Island + Lock Screen navigation activity (ActivityKit)

Both share App Group `group.to.nathancurtis.steddi` with the app.

## Data Flow: Drive-It Route Recording
1. User taps navigate to a pinned location
2. NavigationEngine provides turn-by-turn
3. LocationService simultaneously records raw GPS trace (GPSPoint array on DriveRecord)
4. If user deviates from the suggested route, GPS trace captures actual driven path
5. On arrival, MapMatchingService sends trace to OSRM (chunked at 100 points, stitched)
6. Snapped geometry returned as encoded polyline
7. User prompted to save as preferred route for this commute
