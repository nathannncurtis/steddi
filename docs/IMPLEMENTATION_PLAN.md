# Steddi Implementation Plan & Constitution

This is a living document. It captures every design decision, implementation approach, core philosophy, and technical constraint — and evolves as the project does. When decisions change, this document changes with them. It and the TODO should always reflect the current, exhaustive state of the project's direction. If it's not written here, it hasn't been decided.

---

## Core Philosophy

### This is a magnum opus.
Steddi is a pure passion project — the one thing Nathan would show someone to demonstrate what kind of person he is and what he brings to the table. There is no timeline pressure. Launch happens when the app is genuinely strong, powerful, and standalone. If that means delaying 6 months to keep polishing, that's what happens. Every decision optimizes for quality and completeness, never speed to market.

### Your route, your rules.
This is the product identity. Steddi is built for people who already know their commute and want control over how they drive it. But it should also feel like the standard when you're driving somewhere unfamiliar — a feature-rich, full nav app, not just a commute tool.

### Perfection is in the details.
The things most users won't consciously notice — a gradual color shift at sunset, a subtle haptic approaching a turn, a route line that draws itself onto the map — are exactly what makes Steddi feel crafted rather than built. These details are not post-launch polish. They are the product.

### Keep it free.
No subscription, no paid tier, no recurring costs to the user. The app has a "buy me a coffee" donation system. Infrastructure costs (if any) should be minimized. Prefer on-device solutions over backends. Use Apple's free-tier APIs (WeatherKit 500k calls/mo, MapKit). No paid third-party APIs unless absolutely unavoidable.

### MapKit is a hard line.
No third-party map SDKs. The Mapbox migration already happened — zero third-party map branding, no SDK licensing. MapKit for routing and display, OSM/OSRM for specialized tasks (map matching, road data). If a MapKit wall is hit, find a creative workaround before considering alternatives.

### Settings should not confuse.
The Settings screen surfaces things users reasonably want to tweak: appearance, themes, voice, haptics, display modes, nav UI preferences (mini-player toggle, etc.). Routing-level configuration — no-go zones, route preferences, reroute thresholds, avoid highways/tolls — lives within the context it applies to (the specific commute or trip). Global defaults for routing config exist but are not on the main Settings surface. They're accessible but tucked away. The principle: if a setting only makes sense in the context of a specific route, it belongs with that route, not in a global list where it could confuse someone who just wants to change their accent color.

---

## Technical Foundation

### Architecture
MVVM. SwiftUI views → ViewModels → Services → SwiftData Models. iOS 26+ deployment target. Swift, SwiftUI, UIKit (CarPlay). No CocoaPods — SPM only.

### Map Stack
- **Display & routing:** MapKit (MKMapView, MKDirections, MKRoute)
- **Map matching:** OSRM
- **Geocoding:** MKLocalSearch
- **Road data (tunnels, speed cameras, road segments):** OpenStreetMap
- **Weather:** WeatherKit (first-party, free tier)

### Extension Targets (planned)
- Live Activity widget extension (ActivityKit)
- Home screen widget extension (WidgetKit)
- Apple Watch app + extension (WatchKit, WatchConnectivity) — post-launch

### App Group
Shared container (`group.to.nathancurtis.steddi`) for data sharing between main app and all extensions. Set up before any extension work begins — plumbing in place early so every extension feature is simpler.

### Signing & Distribution
- Automatic code signing, Team ID: Z46423B3U9
- Bundle ID: `to.nathancurtis.steddi`
- CarPlay navigation entitlement: applied, awaiting Apple approval
- CarPlay entitlements removed from build until approved

---

## Implementation Phases

### Phase 1 — Foundation
Do before anything else. These are blockers.

#### Location Tracking Bug
- **Problem:** Location appears to be tracked when no route is active.
- **Action:** Investigate whether this is intentional (direction detection, commute proximity) or a bug (location service not stopping after nav ends).
- **Rule:** If intentional, it must be toggleable and clearly justified to the user. If a bug, fix it. Apple reviewers scrutinize location usage — every mode of location access needs a defensible reason.

#### Route Preview
- **Commutes:** Tap a commute → options for "Go" (skip to nav) or "Preview" (full route on map). If multiple routes are saved, show them in ranked tier order on the preview screen.
- **Dumb nav (search/pinned locations):** Always shows preview first. Not skippable. If you don't know the route, you should see it.
- **Per-commute setting:** Users can disable preview for individual commutes so power users can tap and go.
- **Design tension:** Must serve both "I know this route, get out of my way" and "I'm going somewhere new, let me study this." Same screen, two mindsets.
- **CarPlay compliance:** Apple requires route overview before navigation begins.

#### App Group Setup
- Register shared container in developer account.
- Add App Group entitlement to main app target.
- Shared UserDefaults and file directory ready for extensions.
- Do this as a standalone task before starting Live Activities or widgets.

---

### Phase 2 — Core Polish
This phase makes someone pick up the app and immediately feel like they're holding something crafted.

#### Live Activities + Dynamic Island
- **Data:** ETA, next turn instruction, distance remaining.
- **Surfaces:** Dynamic Island compact, Dynamic Island expanded, Lock Screen Live Activity. Each needs its own layout.
- **Updates:** Push from NavigationEngine on step changes and ETA shifts. Not every GPS tick — Apple throttles update frequency.
- **Lifecycle — aggressive cleanup:**
  - End activity immediately on: nav end (arrival, user taps End, reroute), app terminate (`applicationWillTerminate`), scene disconnect (`sceneDidDisconnect`).
  - Set rolling stale date 5-10 minutes in the future, pushed forward with each update. If updates stop (app crash, iOS kills process), activity auto-stales and user can dismiss.
  - On every app launch, sweep `Activity.activities` and kill any orphaned activities.
  - Zero tolerance for zombie activities on Lock Screen.

#### Haptics
- **Five-level setting:** Off / Subtle / Standard / Dynamic / Advanced
  - **Off:** Nothing.
  - **Subtle:** Everything at low intensity, uniform.
  - **Standard:** Everything at medium intensity, uniform.
  - **Dynamic:** Intensity varies by event type. Turns: light. Reroute suggestions: medium. Arrival: strong. UI interactions: minimal. Best defaults chosen by us.
  - **Advanced:** Same as Dynamic, but user can fine-tune intensity per event category.
- **Events:** Approaching turn, reroute suggestion, arrival confirmation, UI interactions (toggle mute, end nav, report), speed trap/camera alert.
- **Testing:** Must be tested on physical device. Simulator does not support haptics.

#### Animations & Micro-interactions
- **Route draw-on animation:** Custom `MKOverlayRenderer`. Route traces from user's location to destination like a pen drawing on the map. Used in two contexts:
  - **Preview:** Route traces out as camera zooms to fit. This is the "whoa" moment.
  - **Active nav:** Route line subtly extends ahead as new steps load, fades behind as user passes. Line feels alive, not static.
- **Nav overlay:** Entrance/exit transitions when navigation starts and ends.
- **Cards:** Commute cards, reroute suggestions, arrival — all animate with intention.
- **Global rule:** Every screen change should feel intentional. No hard cuts.
- **Performance:** Animations during active nav must not impact GPS update processing.

#### Home Screen Widgets
- **Primary widget:** "Next commute ETA" — shows estimated drive time for user's most relevant commute.
- **Framework:** WidgetKit with timeline provider.
- **Data freshness:** Widgets don't update in real-time. Smart refresh intervals. Clear "as of X min ago" indication so it doesn't feel broken when slightly stale.
- **Requires App Group** for shared data access.

#### Siri Shortcuts / App Intents
- **Intents:** `StartCommuteIntent`, `CheckCommuteETAIntent`, and others.
- **Framework:** App Intents (modern replacement for SiriKit Intents).
- **Key experience:** "Hey Siri, start my commute" — launches nav without opening app. "Hey Siri, how's my drive to work looking?" — returns ETA without opening app.
- **Integration:** Feeds into Shortcuts app for power user automations (e.g., "when I connect to car Bluetooth, check commute ETA"). Ties into smart notifications story — Siri proactively suggesting commute start.

#### Passenger Mode & Accessibility
- **Two separate toggles.** These serve different needs and can be active simultaneously.
- **Passenger mode:** Bigger text, simplified UI. Passenger handles reroute decisions and hazard reports so the driver doesn't touch the phone. Changes *what* you interact with.
- **Accessibility mode:** Larger maneuver icons, higher contrast, simplified instruction language, better VoiceOver support. Changes *how* it looks and reads.
- **Overlap:** A visually impaired passenger would enable both.

#### Onboarding
- First-run experience that communicates quality immediately. Not a tutorial — a "feel."
- Convey core value prop (your route, your rules) without walls of text.
- User should experience the polish within seconds of opening.
- **Emergency contact setup** offered during onboarding (skippable). Always available in Settings later. If user hits emergency button without setup, prompt at that point.

---

### Phase 3 — Differentiators
What makes Steddi irreplaceable.

#### Smart Notifications
- **Commute precheck:** Learn departure patterns on-device (track departure times, detect routine). Before usual departure, check current ETA via MapKit directions. If significantly worse than historical average, fire local notification: "your commute is 40 min slower than usual, consider leaving now."
- **Weather warnings:** WeatherKit check for severe weather affecting commute route. Notify if conditions are dangerous or will cause major delays.
- **Architecture — fully on-device, no backend:**
  - Background app refresh for periodic wake-ups.
  - MapKit directions API for ETA checks (free, on-device).
  - WeatherKit for weather data (500k free API calls/month).
  - Local notifications (no APNs server needed).
  - Tradeoff: iOS controls background refresh timing, so notification may arrive at 6:25am or 6:40am, not exactly 6:30am. Acceptable for "heads up" alerts.
- **Future:** If the app grows and needs precise timing, crowdsourced data aggregation, or cross-user intelligence, a lightweight backend can be layered on later.

#### Commute Analytics
- **Data source:** DriveRecord already captures GPS traces. Extend to persist speed data over time (speedometer data already exists in real-time, just needs recording alongside trace).
- **Derived metrics:** Time spent stopped/crawling (inferred from speed data), average commute time by day of week, trends over weeks/months, total hours spent commuting.
- **UI:** SwiftUI Charts. Think iPhone Screen Time but for driving. Clean summary view for casual users, detailed analytical view for power users (time in traffic breakdowns, speed profiles, trend lines).
- **Insight examples:** "Your Tuesday commute has gotten 8 minutes worse since January." "You spent 14 hours in traffic this month."

#### Speed Traps & Red Light Cameras
- **Data source:** OpenStreetMap speed camera tags (free, community-maintained) + crowdsourced user reports via existing in-app report system. Grows organically. No paid APIs.
- **Alert UX:** Clean and minimal. Small icon on map, subtle haptic or tone on approach. Not noisy like Waze. Respects the haptic intensity setting.
- **Trust:** False alerts erode trust fast. Need confidence scoring or at minimum user confirmation flow.

#### Road Surface & Construction Memory
- **Collection:** Post-arrival prompt: "anything to report about this drive?" Options for potholes, construction, rough roads. Geolocated and associated with the specific route.
- **Surfacing:** On future drives along the same route, surface known conditions (map icon, optional audio/haptic).
- **Data decay rules:**
  - Report lives indefinitely until user drives that road again.
  - First time driving past after 14+ days: "is this still here?" prompt.
  - Confirmed: 14-day timer resets.
  - Dismissed: report removed.
  - Not driven within 90 days of original report: silently expires.
  - No prompts unless user is physically on that road.
- **Long-term value:** Steddi builds a proprietary dataset of *your* specific route conditions. Nobody else has this.

#### Music & Podcast Integration
- **Phone nav UI:** Now Playing mini-bar with album art, song title, play/pause/skip/back buttons. Uses `MPNowPlayingInfoCenter` for metadata and `MPRemoteCommandCenter` for playback control. Works with whatever audio app is active.
- **Full-screen CarPlay nav:** Steddi owns media remote commands. Steering wheel buttons (play/pause/skip/back) handled by Steddi, routed to the active audio app. Long-press skip to seek through track (à la Spotify, via `seekForwardCommand`/`seekBackwardCommand`).
- **CarPlay widget view:** Steddi does not intercept media controls. Native music app handles its own.
- **Design challenge:** Mini-bar must fit into nav overlay without cluttering it.

---

### Phase 4 — Advanced Features

#### Trips
- **Third content type** alongside pinned locations and commutes.
- **Purpose:** Saved routes to non-recurring or one-off destinations. The OCD road trip planner's dream.
- **Features:** Multi-stop waypoints (scenic overlooks, lunch spots, gas stations), reroute thresholds, avoids, route hierarchy (available but not prominently advertised).
- **Nav flow between stops:** Configurable per trip:
  - **Continuous:** Arrive at stop 1, app auto-queues next leg after brief arrival moment. Whole trip is one session.
  - **Manual:** Arrive at stop 1, nav ends. Start next leg when ready. Each stop is its own session.
- **Planning UX:** "I'm making a 2-day 23-hour drive, I want to know where I'm stopping in advance."

#### No-Go Zones v2
- **Input methods:**
  - **Freehand draw:** Trace finger along road, line snaps to road geometry. Quick and intuitive.
  - **Dot-to-dot:** Tap waypoints, app connects them along road network (same paradigm as route planning). Better for precision and longer stretches.
  - **Polygon:** Tap vertices on map to define arbitrary area.
- **Named road avoidance:** "Always avoid the 91 between Main and the 15."
- **Time-based zones:** Active only during specified hours (school zones, construction windows).
- **Technical notes:** Road segment identification likely requires reverse-geocoding taps to OSRM road segments. Routing engine must evaluate all zone types at route-calculation time.

#### Theming & Appearance
The most comprehensive dynamic theming system in any nav app.

- **Theme modes (user-selectable):** Dark / Light / Grey / Dynamic
- **Dynamic mode layers (all blend in real-time):**
  - **Solar position:** Dark at night, light during day. Uses existing GPS-based solar calculation.
  - **Sunset/sunrise:** Warm palette during golden hour. Full 45-minute gradual transition — so slow it's imperceptible. Color interpolation across the entire golden hour window calculated from user's GPS coordinates.
  - **Weather:** Grey mode auto-applies when overcast/rainy. WeatherKit data.
  - **Temperature:** Warmer color tones when hot, cooler/bluer tones when cold. **Relative to local historical norms** — 65°F in SoCal is cold (cool tint), 65°F in Alaska is warm (warm tint). Subtle even at extremes; a sliding scale where the further from "neutral" the more the shift, but never overwhelming.
  - **Tunnel detection:** Quick fade to dark on tunnel entry (GPS signal drop + OSM tunnel data as confirmation), fade back on exit. Timing doesn't need to be perfect — slight delay on entry and slight early exit feels natural since eyes adjust gradually too.
- **Grey mode:** Also available as a standalone theme option independent of Dynamic. A mid-tone palette between light and dark.

#### Route Preferences
- **Toll avoidance:** Uses `MKDirections.Request.tollPreference`. Shows "this route has tolls" as yes/no indicator. Cost estimates deferred until a free data source exists. Surface the tradeoff: "Route A: tolls / Route B: no tolls, +12 min."
- **Avoid highways:** Toggle for elderly/student drivers or anyone who prefers surface streets.
- **Scope:** Both global (Settings) and per-commute toggles.
- **Active indicators:** During nav, user sees when a preference is affecting their route (e.g., "avoiding highways" chip). Important so users aren't confused about unexpected routing.

#### Emergency / Breakdown Mode
- **One tap access:** Share exact location with a contact, pull up nearby services (gas, mechanic, hospital via MKLocalSearch), call roadside assistance.
- **Emergency contact:** Setup offered during onboarding (skippable). Always available in Settings. If user triggers emergency without setup, prompt then.
- **Reachability:** Must be accessible from nav screen without digging through menus. Potentially long-press on report button, or dedicated SOS option.

---

### Phase 5 — Moonshots

#### AI Route Planner
- **v1 (build now):** Fuzzy parser. Handles highway names, street names, and connectors ("to," "via," "exit at") via string parsing + geocoding lookups. No ML model required. Covers ~80% of the practical use case.
- **v2 (deferred):** Full natural language understanding. "Take the 91 to the 15 north, exit at Main." Requires on-device ML. Wait for Apple Intelligence APIs and on-device models to mature. **No forced large ML downloads.** Likely iPhone 15 Pro+ exclusive when it happens.

#### Apple Watch
- **Post-launch.** Whole new platform target (WatchKit UI, WatchConnectivity).
- **Core feature:** Haptic turn-by-turn on wrist. Distinct tap patterns for left/right/straight.
- **Use cases:** Cyclists, runners, motorcyclists, anyone who can't stare at their phone.
- **Signals ecosystem completeness** — Steddi isn't just an iPhone app.

---

## Feature-Specific Design Decisions

### Navigation Categories
Steddi has three types of navigation content:
1. **Pinned locations** — saved places, no route context. Quick "take me there" dumb nav.
2. **Commutes** — bidirectional, recurring, with saved route hierarchies, reroute thresholds, per-commute preferences. The core product.
3. **Trips** — saved multi-stop routes to non-recurring destinations. Full route planning with waypoints, avoids, preferences. The power user tool.

### Voice Guidance
- **Engine:** AVSpeechSynthesizer with selectable premium voices (Ava, Zoe, Tom, Evan, Aaron, Samantha). Falls back to enhanced → compact if premium not downloaded.
- **Mute:** `@AppStorage`-backed toggle synced between Settings and nav overlay. Persists across sessions. Service state synced on nav overlay appear.
- **Offline voices:** AVSpeechSynthesizer voices are OS-managed. Cannot bundle or download programmatically. Can prompt users to download enhanced voices via iOS Settings. May explore pre-generating audio for common instructions as alternative.
- **Audio session:** Playback mode, voice prompt, ducks other audio, interrupts spoken audio.

### Audio Ducking Policy
- **Rule:** Any Steddi audio (voice guidance, alerts, speed trap tones) ducks media playback — never pauses it. Music volume lowers, Steddi audio plays over it, music volume restores. This is the `.duckOthers` AVAudioSession option.
- **Scope:** Applies to all audio events — voice nav instructions, reroute alerts, speed trap/camera alerts, arrival announcements, hazard warnings.
- **Settings:** Voice nav ducking and alert ducking should be combined by default (one "duck media" behavior) but also independently configurable in settings for users who want voice nav to duck but alerts to play at full mix, or vice versa.
- **Already partially implemented:** VoiceGuidanceService uses `.duckOthers`. Needs to be extended to all future alert audio paths.

### Reroute Engine
Sigmoid-scaled threshold based on remaining ETA. Base percentage (user-configurable, default 20%) scaled by a sigmoid curve centered at 30 minutes remaining. Hard minute floor as secondary gate. Re-evaluated continuously. Full algorithm documented in ARCHITECTURE.md.

### Offline Strategy
- Active nav: route geometry + TBT instructions cached on start.
- Auto-delete 5 min after nav ends.
- Manual persistent downloads available.
- Offline mode: TBT works, traffic unavailable (clear UI indicator).

### Data & Privacy
- All user data stored locally via SwiftData. No cloud sync (for now).
- No analytics, no tracking, no third-party SDKs collecting data.
- Location used only for navigation, direction detection, and features the user explicitly opts into.
- Road condition reports stored locally — not shared with other users (for now).
- Privacy policy published at steddi.io.

---

## Technical Constraints & Risks

### Extension Target Sprawl
By Phase 5, the project will have: main app, test target, Live Activity extension, widget extension, Watch app, Watch extension. Shared code management via App Group and potentially a shared framework. Architecture decisions about what lives where need to be made early.

### Background Refresh Timing
iOS controls when background app refresh fires. Smart notifications timing will be approximate (could be 15 min early or late). Acceptable for "heads up" alerts, not suitable for time-critical notifications.

### MapKit Limitations
Known: no toll pricing API, MKPlacemark deprecated in iOS 26. Potential: road segment identification for no-go zones may need OSRM supplementation. Custom map styling (dark map tiles, construction overlays) may have limits. Monitor and find creative workarounds before considering any alternatives.

### Haptics Require Device Testing
UIFeedbackGenerator has no simulator support. All haptic tuning must happen on physical hardware. The five-level system (Off/Subtle/Standard/Dynamic/Advanced) needs extensive real-world testing to get the feel right.

### On-Device Testing
Many features (GPS accuracy, Live Activity behavior, CarPlay, haptics, tunnel detection, speed trap alerts) cannot be meaningfully validated in the simulator. Primary test bed: daily 70-mile round trip commute — streets, highways, multiple route options, hierarchy routes, custom thresholds. The developer is the power user.

---

## Sequencing Principles

1. **Foundation first.** Bugs and missing core features before new features.
2. **Polish before features.** An app with 10 polished features beats one with 20 rough ones.
3. **Screen-by-screen, not feature-by-feature.** Fully polish one experience (nav, home, settings) before moving to the next, so consistency is maintained.
4. **Set up infrastructure early.** App Group before extensions. Speed data recording before analytics. Report system before road memory.
5. **Defer what's evolving.** AI route planner waits for better on-device models. Toll pricing waits for a free data source. Apple Watch waits for core app perfection.
6. **Every feature to v2-v3, then final polish pass.** Build each feature to a solid level, move on, then come back for the final consistency pass across everything at the end.
