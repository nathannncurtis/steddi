# Steddi

iOS navigation app for daily commuters who already know their routes.

Your route, your rules — only rerouted when it actually matters.

## Features
- Pinned places, commutes, and trips — three ways to save where you go
- Drive-it route recording: drive your way once, it's saved (OSRM-snapped)
- Custom turn-by-turn nav engine (no nav SDK) — polyline-first, off-route recovery that keeps forward momentum
- Reroute only when it's worth it — sigmoid-scaled threshold against remaining ETA
- Route preview before nav: alternates, ETA, distance, toll/highway badges
- Route preferences: toll + highway avoidance (global and per-commute)
- No-go zones v2: freehand draw, dot-to-dot, polygon, named road, time-windowed
- Dynamic theming: solar × weather × temperature × tunnel, blended in real time
- Real OSM speed limits with over-limit color bands
- Speed traps + red-light cameras: OSM data plus crowdsourced reports, quiet alerts
- Road-condition memory: report potholes/construction, with decay + reconfirm
- Smart commute notifications: learned departure windows, ETA-vs-typical, weather (on-device)
- Commute analytics: averages by day, time in traffic, trends, drive history (Swift Charts)
- Trips: multi-stop waypoints, continuous or manual leg flow, per-stop planning
- Music + podcast controls with media ducking (voice and alert ducking independently configurable)
- Emergency mode: share location, nearby services, emergency contact, roadside
- Passenger + accessibility modes (text/icon scaling, high contrast, simplified instructions)
- Five-level haptics with per-event intensity
- Voice guidance (AVSpeechSynthesizer) with premium voice picker
- Fuzzy natural-language route parser (highway/street names, connectors)
- CarPlay (CPMapTemplate map, dashboard widget, steering-wheel media)
- Home screen widget + Live Activity (Dynamic Island + Lock Screen)
- Siri Shortcuts (start commute, check ETA)
- Onboarding that conveys the feel, not a tutorial

## Routing
Two engines behind one seam. MapKit (MKDirections) is the user-facing default. A
from-scratch custom router — OSM road graph from Overpass, A* with a pluggable
cost model (generalized turn weighting: protected/unprotected lefts scaled by
oncoming lanes, U-turns, stop signs, signals), per-driver learned weights, and a
corridor-validation harness — is behind a default-off flag. When enabled it's
tried first and auto-falls back to MapKit on any miss, so a drive is never
stranded.

## Stack
- Swift / SwiftUI / UIKit (CarPlay)
- MapKit (MKDirections, MKLocalSearch)
- Custom NavigationEngine for turn-by-turn (no nav SDK)
- Custom road-graph router (OSM/Overpass + A*) behind a default-off flag, MapKit fallback
- OSRM map matching
- WeatherKit (theming + commute weather)
- SwiftData
- WidgetKit + ActivityKit
- App Intents (Siri)
- Swift Charts (analytics)
- MVVM-style: @Observable services as view state
- iOS 26+

## Building
No tokens or API keys. The Xcode project is generated from `project.yml`:

```
xcodegen generate
```

Then build the `Steddi` scheme in Xcode, or `xcodebuild -project Steddi.xcodeproj -scheme Steddi`. See `docs/SETUP.md`.

## Tests
952 Swift tests across 150 suites, plus 76 Python tests for the reroute/CarPlay
state models and a simulated-drive harness (waypoint files on real road geometry).
