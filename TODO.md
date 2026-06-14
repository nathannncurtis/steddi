# Steddi TODO

## Priority 1 — Verify on the Road
- All seven March real-drive bugs are fixed in code and simulator-verified — needs the 70-mile commute to confirm: stable compass, plot-point ETAs, forward-momentum off-route recovery, puck centered and smooth, traffic rendering, real OSM speed limits with visible over-limit colors
- Prompt to download the selected premium voice when it isn't installed (fallback now shows honest system-default state, but no download nudge yet)

## Custom Routing Engine — Real-Corridor Tuning
- Engine is built and unit-/fixture-tested (OSM graph + A* + cost model + learned weights + corridor validator), behind a default-off flag with automatic MapKit fallback
- Tune cost weights against real corridors before flipping the flag on for anyone — turn penalties and road-class multipliers are sane defaults, not road-tested
- Persist RouterEngine provenance on saved Routes (currently provenance only lives on the in-memory GeneratedRoute; Route stores RouteSource, not which engine produced it)
- Validate the learned-weights path against actual drive history on the road
- Make custom-router travel time traffic-aware, or keep ETA on MapKit (current design keeps reroute ETA on MapKit deliberately)

## Voice & Offline
- Download voice packs for offline use (support offline mapping end-to-end)
- Note: AVSpeechSynthesizer voices are OS-managed — can prompt users to download enhanced voices in Settings but can't bundle them. May need to explore pre-generating audio for common instructions as alternative.
- Wire OfflineCacheService's active-navigation cache into nav (cacheActiveRoute/scheduleCleanup/loadCachedRoute have no callers yet)
- Cache turn-by-turn instructions, not just geometry/distance/duration
- Offline turn-by-turn and traffic data

## Wearables
- Apple Watch support — vibration-based turn alerts for accessibility (post-launch)

## App Store Prep
- TestFlight beta testing
- App Store submission

## Requires Physical Device
- On-device GPS testing (arrival detection, map matching, route recording)
- NavigationEngine real-world validation
- Daily 70-mile round trip commute (streets + highways, multiple route options) as primary test bed
- CarPlay verification on a real head unit (CPMapTemplate map view, dashboard widget, steering wheel media controls)

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
- Code cleanup (dead code, worktree artifacts, debug logs removed)
- Proper code signing with Apple Developer account
- Landscape nav UI: bigger elements, horizontal button row
- Landscape home: cards no longer clipped
- Navigation voice guidance (AVSpeechSynthesizer)
- Voice mute bug fix (settings toggle now syncs with nav overlay)
- Premium voice options with voice picker in settings
- Fixed interface orientations warning
- Website live at steddi.io (video hero, slide-in showcase, privacy section, waitlist CTA, EmailJS, GitHub Pages, custom domain)
- CarPlay navigation entitlement approved and re-enabled (key: carplay-maps)
- Website rebuilt: personal tone, expanded features, craft section, philosophy, animations, auto-deploy via GitHub Actions
- Fix: compass uses route-based bearing for stable cardinal direction
- Fix: puck snapped to route polyline (centered on route line)
- Fix: smooth puck movement with 0.8s easeOut animation (no jitter)
- Fix: speedometer color changes when exceeding estimated speed limit
- Fix: traffic conditions now shown on map
- Fix: location tracking downgraded when not navigating (no background tracking without active route)
- Fix: off-route detection with smart rerouting (avoids U-turns, prioritizes forward momentum)
- Route preview before nav starts (full-screen map, ETA, distance, alternate routes, toll/highway indicators)
- Route preferences: toll and highway avoidance (global Settings toggles + per-commute overrides)
- Haptic feedback system (Off/Subtle/Standard/Dynamic/Advanced, per-event intensity, wired into nav engine)
- Siri Shortcuts via App Intents ("Start my commute", "Check commute ETA")
- App Group entitlement enabled in developer portal and project
- CarPlay swapped to CPMapTemplate with full map view, maneuver display, zoom controls
- NavigationEngine rewritten from scratch: unified NavStep model, polyline-first architecture
- CustomRouteBuilder: generates steps from polyline geometry (fallback for old routes)
- Saved routes now store turn-by-turn steps from planning time (no more runtime inference)
- Route planner saves Apple's real instructions alongside the polyline
- ETA uses saved travel time from planning, not 30mph assumption
- Compass shows device magnetometer heading (direction phone faces)
- Free-look mode during nav (pan/pinch pauses camera, recenter button to resume)
- Per-commute route preview skip option
- CarPlay dashboard widget with shortcut buttons
- CarPlay Now Playing integration with steering wheel media controls
- Live Activities: Dynamic Island compact/expanded, Lock Screen, activity lifecycle
- Home screen widget: commute ETA (small + medium sizes, App Group shared data)
- Commute Analytics view with Swift Charts (avg by day, time in traffic, recent drives)
- Emergency / Breakdown mode (share location, nearby services, emergency contact, roadside)
- Passenger mode + Accessibility mode (display toggles, text/icon scaling)
- Fuzzy route parser for natural language route input
- Website rebuilt: hero map animation, 3D mockups, animated icons, roadmap page, live repo sync
- Fix: CarPlay crash — completion handlers on all template operations (nil completion crashes on error)
- Fix: CarPlay dashboard scene now routed in AppDelegate (was falling through to PhoneSceneDelegate)
- Fix: .onOpenURL replaced with NotificationCenter (incompatible with UIKit lifecycle, crashed on CarPlay connect)
- CarPlay: CPMapTemplate as permanent root, CPMapTemplateDelegate for pan/banners, free-look mode
- Note: CPMapTemplate crashes on iOS 26.4 simulator (Apple bug in CPSMapTemplateViewController._updateShareButtonVisibility) — works on 26.3
- Live Activity lifecycle hardening: rolling stale date (10 min), orphan sweep on launch, end on nav end/stop/terminate/scene disconnect
- Fix: compass reads engine travel bearing with sector hysteresis (magnetometer no longer drives it)
- Fix: unified nav pose — puck rides the snapped route on a display-link clock, camera and compass agree
- Fix: traffic renders on home/nav/preview/planner maps (muted emphasis was silently disabling it)
- Fix: planned-route ETA — plot points are pass-through vias (OSRM), spur-trimmed fallback, legacy duration migration
- Off-route recovery: forward rejoin targets, macro legs over micro waypoints, no U-turn default, ungated from reroute threshold
- OSM speed limits: corridor prefetch, spatial lookup with heading filter, amber/red over-limit bands
- Widget shows commute and destination names, timelines reload on nav transitions
- Siri "Check Commute ETA" answers with live ETA from the shared store (SwiftData moved to App Group with safe migration)
- Accessibility/passenger modes applied: text/icon/control scaling, high contrast, simplified instructions
- Advanced haptics fine-tuning UI with per-event intensity sliders
- Voice picker hardened: off-main catalog probe, honest system-default state, crash fix on empty voice catalog
- Simulated-drive test harness: waypoint files on real road geometry, drive.sh, off-route replay tests
- Trips: third saved-route category (multi-stop waypoints, continuous/manual leg flow, per-stop planning, UUID-based progression state machine)
- Dynamic theming: solar × weather × temperature × tunnel layers blended in real time
- Grey mode (standalone theme + weather-driven), temperature tinting relative to local climate norms, sunset/sunrise golden-hour transition, tunnel fade-to-dark
- WeatherKit integration (theming + commute weather)
- No-go zones v2: freehand (road-snapped), dot-to-dot, polygon, named road, time-windowed activation
- Smart commute notifications: learned departure windows + ETA-vs-typical + weather, on-device via BackgroundTasks, pure decision engine
- Route draw-on / route-extends-ahead animations, nav overlay transitions, card animations
- Music + podcast: Now Playing mini-bar, CarPlay media remote, long-press seek; audio ducking (voice and alert independently configurable, ducks media never pauses)
- Speed traps + red-light cameras: OSM camera nodes + crowdsourced reports unified in one spatial index, quiet proximity alerts, report from nav overlay
- Road surface & construction memory: per-route conditions, post-arrival report prompt, decay + reconfirm lifecycle
- POI: search result offers Navigate vs Save Place, Add Place flow, pin categories with icons, Yelp/Google/Apple Maps review link-outs
- Onboarding: first-run feel (hero, permissions, theme, emergency-contact setup), skippable
- Custom routing engine: OSM road graph (Overpass) + binary serializer + corridor disk cache, A* with snap-to-graph + binary heap, pluggable cost model (generalized turn weighting, protected/unprotected lefts scaled by oncoming lanes, U-turns, stop signs, signals, road-class multipliers, no-go zones, time-of-day), StepSynthesizer to NavSteps, per-driver learned weights, corridor-validation harness, RouteProvider seam with default-off flag and automatic MapKit fallback
- Test coverage: 952 Swift tests across 150 suites + 76 Python tests
