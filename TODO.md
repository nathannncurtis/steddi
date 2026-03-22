# Steddi TODO

## Priority 1 — Bugs
- CommuteDirectionResolver.resolve() calls in HomeView omit the `trips:` parameter — learned patterns are never used, always falls back to smart defaults

## Priority 2 — Features (Backend Done, Needs UI)
- Offline route download buttons in CommuteDetailView (OfflineCacheService is complete, no UI to trigger downloads or show offline status)
- Donation prompt at milestones (30 days installed, 50 commutes) — DonationView exists but only shows in onboarding/settings, no milestone tracking

## Priority 3 — Future
- CarPlay support (requires CarPlay entitlement + SceneDelegate)
- Custom voice guidance (currently uses Mapbox standard voices)
- App icon and branding
- App Store listing copy and screenshots

## Priority 4 — Requires Physical Device
- On-device GPS trace testing (map matching, route recording)
- Apple Developer account + TestFlight
- App Store submission
