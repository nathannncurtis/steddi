# Steddi TODO

## Priority 1 — Polish
- Navigation voice guidance (currently silent — no TTS for maneuvers)

## Priority 2 — Website (steddi.io)
- Scroll-driven hero video animation (video exists, needs proper integration)
- Porsche-style layout: full-bleed sections, parallax, progressive reveals
- Need fresh app screenshots with device frames for the site
- React + Vite project at ~/projects/steddi-website

## Priority 3 — CarPlay
- Waiting on CarPlay navigation entitlement approval
- Once approved: swap CPListTemplate → CPMapTemplate for full map view
- CarPlayMapController already written and ready

## Priority 4 — App Store Prep
- Fresh screenshots with iPhone device frames
- TestFlight beta testing
- App Store submission

## Priority 5 — Requires Physical Device
- On-device GPS testing (arrival detection, map matching, route recording)
- NavigationEngine real-world validation

## Done ✅
- MapKit migration (removed Mapbox entirely — zero logos)
- Custom NavigationEngine replacing MapboxNavigationCore
- OSRM map matching replacing Mapbox Map Matching
- MKLocalSearch replacing Mapbox Geocoding
- 6 accent colors with live updates across all UI + puck + route line
- Dark/Light/Dynamic theme mode (time-of-day based)
- Unified commute cards with both directions + instant distance + background ETA
- Proximity-only direction resolver (500ft threshold)
- Configurable time-based direction rules per commute
- Icon picker for pinned locations
- Commute creation from home screen
- Scrollable commute/places tabs (max 2 visible)
- Reorderable places
- CarPlay TBT list with route preview flow (select → preview → confirm → navigate)
- Phone companion view for CarPlay
- URL schemes for testing (navigate, search, arrive, reset-onboarding)
- S-curve road app icon (fixed asset catalog)
- Reroute engine with sigmoid-scaled thresholds
- No-go zones (global + per-route)
- Offline route caching
- Donation milestones
- Saved route routing fix
- App Store listing copy + privacy policy
- Test coverage updated post-migration
- Code cleanup (dead code, worktrees, debug logs removed)
- 141+ tests (Swift + Python)
