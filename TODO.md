# Steddi TODO

## Priority 1 — Website (steddi.io)
- Waitlist form / email capture (currently button goes nowhere)
- Deploy to GitHub Pages or Vercel
- Custom domain (steddi.io)

## Priority 2 — CarPlay
- Waiting on CarPlay navigation entitlement approval
- Once approved: swap CPListTemplate → CPMapTemplate for full map view
- CarPlayMapController already written and ready

## Priority 3 — Live Activities
- Live Activity for active navigation (ETA, next turn, distance remaining)
- Dynamic Island compact/expanded views
- Lock Screen widget

## Priority 5 — App Store Prep
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
- Dark/Light/Dynamic theme mode (real solar calculation based on GPS)
- Unified commute cards with both directions + instant distance + background ETA
- Proximity-only direction resolver (500ft threshold)
- Configurable time-based direction rules per commute
- Icon picker for pinned locations
- Commute creation from home screen
- Scrollable commute/places tabs (max 2 visible, no limit in landscape)
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
- Test coverage (181 tests: 105 Swift + 76 Python)
- Code cleanup (dead code, worktree artifacts, debug logs removed)
- Proper code signing with Apple Developer account
- Applied for CarPlay navigation entitlement
- Landscape nav UI: bigger elements, horizontal button row
- Landscape home: cards no longer clipped
- Website: video hero, slide-in showcase, privacy section, waitlist CTA
- Navigation voice guidance (AVSpeechSynthesizer)
- Voice mute bug fix (settings toggle now syncs with nav overlay)
- Premium voice options with voice picker in settings
- Fixed interface orientations warning
- Removed CarPlay entitlements (pending Apple approval)
