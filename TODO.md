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

## No-Go Zones v2
- Support road/street segment selection — tap or trace a stretch of road to avoid, not just circular areas
- Polygon drawing — let users define arbitrary shapes on the map
- Named road avoidance — e.g. "always avoid the 91 between Main and the 15"
- Time-based no-go zones — avoid certain areas only during specific hours (school zones, construction)

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

## Speed Traps & Red Light Cameras
- Database of speed traps and red light camera locations (crowdsourced or third-party dataset)
- Clean, minimal alert — subtle audio or haptic when approaching, not noisy like Waze

## Commute Analytics
- Surface drive history data: average commute time by day of week, trends over time
- Detailed analytical view for power users — time spent sitting in traffic, total time spent commuting to/from work over weeks/months
- Trend insights like "your Tuesday commute has gotten 8 minutes worse since January"

## Siri Shortcuts / App Intents
- "Hey Siri, start my commute" / "Hey Siri, how's my drive to work looking?"
- Deep iOS integration — Siri proactively suggesting commute start ties into smart notifications story

## Music & Podcast Integration
- Now Playing mini-bar in nav UI — skip/pause without leaving the app
- Especially important for full-screen CarPlay where you want to avoid switching to widget view
- Audio ducking on voice guidance already exists, this extends the experience

## Road Surface & Construction Memory
- Remember reported potholes, construction, road conditions on specific routes
- Arrival notification prompt should ask about road conditions encountered during the drive
- Over time Steddi learns actual conditions on your routes — very on-brand for "your route"

## Theming — Sunset/Sunrise Mode
- A warm in-between theme for golden hour transitions — sits between light and grey
- Super gradual color shift where you barely notice the change happening
- Complements the existing solar-based dynamic theming

## Emergency / Breakdown Mode
- One tap: share exact location with a contact, pull up nearby services, call roadside assistance
- Should be part of onboarding — set up emergency contact during first run
- Hopefully never used, but when you need it, you really need it

## Route Preferences
- Toll avoidance with cost estimates — show "this route has $4.50 in tolls, this one adds 12 min but is free" and let user decide
- Avoid highways toggle — for elderly/student drivers or anyone who doesn't like freeways
- Both global and per-commute toggles
- Active indicators during nav so user knows when a preference is affecting their route

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
