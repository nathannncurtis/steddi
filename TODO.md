# Steddi TODO

## Priority 1 — Bugs
- Navigation camera still not matching Apple Maps behavior — needs more tuning
- Commute routing broken: everything shows 5 min ETA, nav stops mid-road. Likely direction resolver or destination logic issue. Direct pin-to-location routing works fine.

## Priority 2 — Polish
- Theme mode picker: dark / light / dynamic — should be part of onboarding AND in settings. If dark: map + UI always dark. If light: always light. If dynamic: follows system. Currently always forced dark.
- Floating nav buttons spacing may need adjustment after migration

## Priority 3 — Features
- CarPlay map view (requires Apple navigation entitlement — apply after dev account)
- Custom voice guidance
- App Store listing copy and screenshots
- Website (steddi.io) — React+Vite site in progress, needs scroll video animation + Porsche-style layout

## Priority 4 — Requires Physical Device / Account
- On-device GPS trace testing
- Apple Developer account ($99) + TestFlight
- CarPlay navigation entitlement application
- App Store submission
