# Steddi TODO

## Priority 1 — Bugs
- Commute routing with saved routes: waypoints from saved polyline not actually used in MKDirections request (falls back to direct route)
- NavigationEngine arrival detection may trigger too early/late — needs real-world testing

## Priority 2 — Polish
- Theme mode picker: add to onboarding flow (page exists but needs testing across all screens)
- Configurable time-based direction rules per commute (e.g. "Mon-Fri 6-10am → Work, 3-7pm → Home") — currently proximity-only
- Commute card: show ETA alongside distance (background fetch, non-blocking — distance shows instantly, ETA fills in when ready)
- Navigation voice guidance (currently silent — no TTS for maneuvers)

## Priority 3 — Website (steddi.io)
- Scroll-driven hero video animation (video exists, needs proper integration)
- Porsche-style layout: full-bleed sections, parallax, progressive reveals
- Need fresh app screenshots with device frames for the site
- React + Vite project at ~/projects/steddi-website

## Priority 4 — CarPlay
- Apply for Apple Developer account ($99) + CarPlay navigation entitlement
- Once approved: swap CPListTemplate → CPMapTemplate for full map view on CarPlay
- CarPlayMapController already written and ready

## Priority 5 — App Store Prep
- Fresh screenshots with iPhone device frames
- App Store listing copy
- Privacy policy for steddi.io
- TestFlight beta testing
- App Store submission

## Done ✅
- MapKit migration (removed Mapbox entirely — zero logos)
- Custom NavigationEngine replacing MapboxNavigationCore
- OSRM map matching replacing Mapbox Map Matching
- MKLocalSearch replacing Mapbox Geocoding
- 6 accent colors with live updates across all UI + puck + route line
- Dark/Light/Dynamic theme mode (time-of-day based)
- Unified commute cards with both directions + instant distance
- Proximity-only direction resolver (500ft threshold)
- Icon picker for pinned locations
- Commute creation from home screen
- Scrollable commute/places tabs (max 2 visible)
- Reorderable places
- CarPlay TBT list (working without map — needs entitlement for CPMapTemplate)
- Phone companion view for CarPlay
- URL schemes for testing (navigate, search, arrive, reset-onboarding)
- S-curve road app icon
- Reroute engine with sigmoid-scaled thresholds
- No-go zones (global + per-route)
- Offline route caching
- Donation milestones
- 141+ tests (Swift + Python)
