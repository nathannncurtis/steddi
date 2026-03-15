# Steddi Architecture

## Overview
MVVM architecture. SwiftUI views bind to ViewModels which coordinate between Services and SwiftData Models.

```
Views (SwiftUI)
  HomeView, NavigationView, SettingsView
    |
    | @Observable / @Bindable
    v
ViewModels
  HomeVM, NavigationVM, CommuteVM, SettingsVM
    |                  |
    v                  v
Services            Models (SwiftData)
  LocationService     PinnedLocation
  MapMatchingService  Commute
  RerouteEngine       Route
  DirectionsService   DriveRecord
  NavigationService   NoGoZone
  OfflineCacheService
```

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

### Example scenarios:
- 90 min remaining, fallback saves 8 min (8.9%): scaled threshold ~10%. Below. Hard floor 10 min not met. No reroute.
- 90 min remaining, fallback saves 12 min (13.3%): scaled threshold ~10%. Above. Reroute suggested.
- 20 min remaining, fallback saves 8 min (40%): scaled threshold ~26%. Above. Reroute suggested.
- 20 min remaining, fallback saves 3 min (15%): scaled threshold ~26%. Below. Hard floor not met. No reroute.

## Offline Strategy
- Active navigation: route geometry + turn-by-turn instructions cached on start
- Cache persists 5 minutes after navigation ends, then auto-deletes
- Users can manually download routes for persistent offline access
- Offline mode: turn-by-turn works, traffic data unavailable (clear UI indicator)

## Mapbox Integration Points
| Feature | Mapbox API/SDK | When Used |
|---------|---------------|-----------|
| Map display | Maps SDK (via Nav SDK) | Always |
| Turn-by-turn | Navigation SDK | Active navigation |
| Traffic ETAs | Directions API (driving-traffic) | Reroute evaluation |
| Route snapping | Map Matching API | After drive-it recording |
| Custom routes | BYOR (Bring Your Own Route) | Navigating saved routes |

## Data Flow: Drive-It Route Recording
1. User taps navigate to a pinned location
2. Mapbox Navigation SDK provides turn-by-turn
3. LocationService simultaneously records raw GPS trace
4. If user deviates from Mapbox suggestion, GPS trace captures actual driven path
5. On arrival, MapMatchingService sends trace to API (chunked if >100 points)
6. Snapped geometry returned as encoded polyline
7. User prompted to save as preferred route for this commute
