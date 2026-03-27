# Steddi TODO

## Priority 1 — Bugs & Fixes
- Location is being tracked when no route is active — if intentional, needs to be toggleable and justified to the user
- Route preview before nav starts (needed for CarPlay compliance, should also be in phone version)

## Priority 2 — CarPlay
- Waiting on CarPlay navigation entitlement approval
- Once approved: swap CPListTemplate → CPMapTemplate for full map view
- CarPlayMapController already written and ready

## Priority 3 — Live Activities
- Live Activity for active navigation (ETA, next turn, distance remaining)
- Dynamic Island compact/expanded views
- Lock Screen widget

## Theming & Appearance
- Weather-based theming (adapt UI to current weather conditions)
- "Grey mode" — both a standalone theme option between light and dark, AND part of weather-based dynamic theming (e.g. auto-applies when rainy/overcast)

## Voice & Offline
- Download voice packs for offline use (support offline mapping end-to-end)
- Note: AVSpeechSynthesizer voices are OS-managed — can prompt users to download enhanced voices in Settings but can't bundle them. May need to explore pre-generating audio for common instructions as alternative.

## Pinned Locations & POI
- Categories for pinned locations with icons (home, gym, work, etc. + various other icons)
- Yelp and/or Google Reviews for POI — link out to browser rather than embed (keeps it lightweight, avoids API cost/ToS issues). Steddi should feel like a full nav app when driving somewhere unfamiliar, not just a commute tool.

## Smart Notifications
- Precheck for frequent commutes based on time of day — e.g., if user usually commutes to work around 7am but there's an hour delay, notify them to leave earlier
- Harsh weather event warnings that would affect traffic on their commute
- Will need a lightweight backend for traffic polling + push notifications — keep cheap initially

## Widgets & Wearables
- Home screen widgets
- Apple Watch support — vibration-based turn alerts for accessibility

## Animations & Micro-interactions
- Nav overlay entrance/exit transitions
- Route draw-on animation when navigation starts
- Card animations (commute cards, reroute suggestions, arrival)
- Smooth state transitions throughout the app — every screen change should feel intentional

## Haptics
- Subtle tap approaching a turn
- Distinct pattern for reroute suggestions
- Arrival confirmation haptic
- Haptic feedback on key UI interactions (toggle mute, end nav, report)
- Different intensity/patterns so the user can feel what's happening without looking

## Onboarding
- First-run experience that communicates quality immediately — not a tutorial, more of a "feel"
- Should convey core value prop (your route, your rules) without walls of text
- Let users experience the polish within seconds of opening

## AI Route Planner
- Natural language route planning — user types street names or describes route in plain language instead of manual GUI planning
- Must run on-device, so likely iPhone 15 Pro+ exclusive (Apple Intelligence / Core ML)

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
- Website live at steddi.io (video hero, slide-in showcase, privacy section, waitlist CTA, EmailJS, GitHub Pages, custom domain)
