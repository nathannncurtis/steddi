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
  MapMatchingService      GeocodingService (MKLocalSearch)
  CustomRouteBuilder      OfflineCacheService*
  VoiceGuidanceService    HapticService
  LiveActivityService     FuzzyRouteParser
  (* = @Observable, as is NavigationStateManager; the
   rest are plain classes/singletons, RerouteEngine a struct)
    |
    v
Models (SwiftData)
  PinnedLocation, Commute, Route, DriveRecord, NoGoZone, CommuteTrip, Report
```

## Navigation Engine
Custom turn-by-turn engine — no navigation SDK. NavigationEngine works entirely from coordinates and its own NavStep model; MKRoute is just an input adapter. Polyline-first: position snapping, step transitions, arrival, and off-route detection (80 m perpendicular distance, 5 consecutive hits) are all computed against the route polyline. CustomRouteBuilder generates NavSteps from raw polyline geometry as a fallback for saved routes that predate stored steps.

NavigationStateManager mirrors engine state on a 500 ms poll, feeds CarPlay, runs a periodic reroute check, and writes ETA to the shared App Group for the widget. The Live Activity is not driven by the state manager — HomeView's location-feed loop calls LiveActivityService directly with NavigationEngine state every 6th 500 ms tick (~every 3 seconds).

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

## MapKit / OSRM Integration Points
| Feature | API | When Used |
|---------|-----|-----------|
| Map display | MKMapView (phone + CarPlay) | Always |
| Routing & traffic ETAs | MKDirections | Planning, previews, reroute evaluation |
| Place search | MKLocalSearch | Search, fuzzy route parsing |
| Route snapping | OSRM Map Matching (router.project-osrm.org) | After drive-it recording |
| Turn-by-turn | Custom NavigationEngine | Active navigation |

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
