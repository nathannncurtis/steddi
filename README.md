# Steddi

iOS navigation app for daily commuters who already know their routes.

Your route, your rules — only rerouted when it actually matters.

## Stack
- Swift / SwiftUI / UIKit (CarPlay)
- MapKit (MKDirections, MKLocalSearch)
- Custom NavigationEngine for turn-by-turn (no nav SDK)
- OSRM map matching
- SwiftData
- MVVM-style: @Observable services as view state
- iOS 26+

## Building
No tokens or API keys. The Xcode project is generated from `project.yml`:

```
xcodegen generate
```

Then build the `Steddi` scheme in Xcode, or `xcodebuild -project Steddi.xcodeproj -scheme Steddi`. See `docs/SETUP.md`.
