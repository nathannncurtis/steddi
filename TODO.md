# Steddi TODO

## Priority 1 — Bugs & Fixes
- App Group entitlement needs to be enabled in Apple Developer portal (code is ready, blocked on provisioning)
- Route preview per-commute disable setting (preview UI is built, commute skip not yet wired)

## Priority 2 — CarPlay
- Test CPMapTemplate on real CarPlay (map view implemented, needs real device verification)
- Verify steering wheel media controls work with Now Playing integration (future)

## Priority 3 — Live Activities
- Live Activity for active navigation (ETA, next turn, distance remaining)
- Dynamic Island compact/expanded views
- Lock Screen widget
- Aggressive lifecycle cleanup: end activity on nav end, app terminate, scene disconnect. Stale date rolling 5-10 min ahead so zombie activities auto-dim if app dies. On launch, always sweep for orphaned activities.

## Trips
- Third category alongside pins and commutes — saved routes to non-recurring or one-off destinations
- Full-featured: multi-stop waypoints, reroute thresholds, avoids, route hierarchy (available but not front-and-center)
- OCD planner's dream: plan scenic stops, lunch spots, gas stations in advance for long drives
- Nav flow between stops: configurable per trip — continuous (auto-queue next leg on arrival) or manual (end nav, start next leg when ready)

## Theming & Appearance
- Weather-based theming (WeatherKit — adapt UI to current conditions)
- "Grey mode" — both a standalone theme option between light and dark, AND part of weather-based dynamic theming (auto-applies when rainy/overcast)
- Temperature-based tinting — warmer tones when hot, cooler tones when cold. Relative to local historical norms (65°F in SoCal ≠ 65°F in Alaska). Subtle even at extremes.
- Sunset/sunrise mode — warm palette during golden hour, full 45-min gradual transition so the shift is imperceptible. Uses existing solar calculation infrastructure.
- Tunnel detection — quick fade to dark mode on tunnel entry (GPS signal drop + OSM tunnel data), fade back on exit. Timing doesn't need to be perfect — slight delay on entry and early on exit feels natural.
- Full dynamic theme layers: solar position × weather × temperature × tunnel, all blending in real-time

## Voice & Offline
- Download voice packs for offline use (support offline mapping end-to-end)
- Note: AVSpeechSynthesizer voices are OS-managed — can prompt users to download enhanced voices in Settings but can't bundle them. May need to explore pre-generating audio for common instructions as alternative.

## Pinned Locations & POI
- Categories for pinned locations with icons (home, gym, work, etc. + various other icons)
- Yelp and/or Google Reviews for POI — link out to browser rather than embed (keeps it lightweight, avoids API cost/ToS issues). Steddi should feel like a full nav app when driving somewhere unfamiliar, not just a commute tool.

## No-Go Zones v2
- Freehand draw with road snapping — trace a stretch of road to avoid
- Dot-to-dot waypoint mode — tap points, app connects them along the road network
- Polygon drawing — let users define arbitrary shapes on the map
- Named road avoidance — e.g. "always avoid the 91 between Main and the 15"
- Time-based no-go zones — avoid certain areas only during specific hours (school zones, construction)

## Smart Notifications
- Precheck for frequent commutes based on time of day — e.g., if user usually commutes to work around 7am but there's an hour delay, notify them to leave earlier
- Harsh weather event warnings that would affect traffic on their commute
- Fully on-device: background app refresh + MapKit ETA check + WeatherKit (500k free calls/mo) + local notifications. No backend needed for v1.

## Widgets & Wearables
- Home screen widgets ("next commute ETA" — WidgetKit with timeline provider, smart refresh intervals)
- Apple Watch support — vibration-based turn alerts for accessibility (post-launch)

## Animations & Micro-interactions
- Route draw-on animation via custom MKOverlayRenderer — route traces from your location to destination on preview
- Active nav: route line subtly extends ahead, fades behind you as you pass
- Nav overlay entrance/exit transitions
- Card animations (commute cards, reroute suggestions, arrival)
- Smooth state transitions throughout the app — every screen change should feel intentional

## Haptics
- Five-level setting: Off / Subtle / Standard / Dynamic / Advanced
- Dynamic: intensity varies by event type (turns light, reroute medium, arrival strong, UI minimal)
- Advanced: Dynamic but user can fine-tune intensity per event category
- Events: approaching turn, reroute suggestion, arrival, UI interactions (toggle mute, end nav, report), alerts

## Speed Traps & Red Light Cameras
- OSM speed camera data + crowdsourced user reports (free, grows organically)
- Clean, minimal alert — subtle audio or haptic when approaching, not noisy like Waze

## Commute Analytics
- Surface drive history data: average commute time by day of week, trends over time
- Detailed analytical view for power users — time spent sitting in traffic, total time spent commuting to/from work over weeks/months
- Trend insights like "your Tuesday commute has gotten 8 minutes worse since January"
- Record speed data over time during drives (speedometer data already exists, just needs to be persisted)

## Siri Shortcuts / App Intents
- "Hey Siri, start my commute" / "Hey Siri, how's my drive to work looking?"
- Deep iOS integration — Siri proactively suggesting commute start ties into smart notifications story

## Music & Podcast Integration
- Now Playing mini-bar in phone nav UI — album art, song title, play/pause/skip/back buttons. Toggleable in settings (some users won't want it cluttering the nav view).
- Full-screen CarPlay nav: Steddi owns media remote commands (play/pause/skip/back/long-press-seek via steering wheel)
- CarPlay widget view: native music app handles its own controls
- Long-press skip to seek through track (à la Spotify)
- Audio ducking for ALL Steddi sounds (voice nav, alerts, speed trap tones) — always duck media, never pause. Combined by default but voice nav ducking and alert ducking independently configurable in settings.

## Road Surface & Construction Memory
- Remember reported potholes, construction, road conditions on specific routes
- Post-arrival prompt: "anything to report about this drive?"
- Data decay: report lives until you drive past again after 14+ days → "is this still here?" prompt. If not driven within 90 days, silently expires. Confirmed reports reset the 14-day timer.

## Emergency / Breakdown Mode
- One tap: share exact location with a contact, pull up nearby services, call roadside assistance
- Onboarding offers emergency contact setup (skippable, always available in settings later)
- If user hits emergency button without setup, prompt then

## Passenger Mode & Accessibility
- Passenger mode: separate toggle. Bigger text, simplified UI, passenger handles reroute decisions and reports so driver doesn't touch the phone
- Accessibility mode: separate toggle. Larger maneuver icons, higher contrast, simplified instruction language
- Both can be active simultaneously (visually impaired passenger)

## Route Preferences
- Toll avoidance — "this route has tolls" indicator (MKDirections tollPreference). Cost estimates deferred until a free data source exists.
- Avoid highways toggle — for elderly/student drivers or anyone who doesn't like freeways
- Both global and per-commute toggles
- Active indicators during nav so user knows when a preference is affecting their route

## Onboarding
- First-run experience that communicates quality immediately — not a tutorial, more of a "feel"
- Should convey core value prop (your route, your rules) without walls of text
- Let users experience the polish within seconds of opening
- Emergency contact setup offered here (skippable)

## AI Route Planner
- Fuzzy parser for now — handles highway names, street names, connectors ("to," "via," "exit at") with string parsing + geocoding. No ML model required.
- Full natural language version deferred until Apple Intelligence / on-device models mature. No forced large ML downloads.

## App Store Prep
- TestFlight beta testing
- App Store submission

## Requires Physical Device
- On-device GPS testing (arrival detection, map matching, route recording)
- NavigationEngine real-world validation
- Daily 70-mile round trip commute (streets + highways, multiple route options) as primary test bed

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
- Navigation voice guidance (AVSpeechSynthesizer)
- Voice mute bug fix (settings toggle now syncs with nav overlay)
- Premium voice options with voice picker in settings
- Fixed interface orientations warning
- Removed CarPlay entitlements (pending Apple approval)
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
- App Group entitlement added (pending portal setup)
- CarPlay swapped to CPMapTemplate with full map view, maneuver display, zoom controls
- NavigationEngine rewritten from scratch: unified NavStep model, polyline-first architecture
- CustomRouteBuilder: generates steps from polyline geometry (fallback for old routes)
- Saved routes now store turn-by-turn steps from planning time (no more runtime inference)
- Route planner saves Apple's real instructions alongside the polyline
- ETA uses saved travel time from planning, not 30mph assumption
- Compass shows device magnetometer heading (direction phone faces)
- Free-look mode during nav (pan/pinch pauses camera, recenter button to resume)
- Removed .claude/skills from repo
