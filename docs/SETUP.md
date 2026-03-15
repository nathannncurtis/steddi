# Steddi Development Setup

## Prerequisites
- Xcode 15.0+ (Swift 5.9+)
- iOS 17+ device or simulator
- Mapbox account (free tier)

## Mapbox Configuration

### 1. Get your tokens
Go to https://account.mapbox.com/access-tokens/

You need two tokens:
- **Public token** (default): Used in the app at runtime
- **Secret token**: Create one with Downloads:Read scope. Used only for SPM to fetch the SDK.

### 2. Configure secret token for SPM downloads
Add to ~/.netrc on your Mac:
```
machine api.mapbox.com
login mapbox
password YOUR_SECRET_TOKEN
```

### 3. Configure public token in app
Set MBXAccessToken in Steddi/Info.plist:
```xml
<key>MBXAccessToken</key>
<string>YOUR_PUBLIC_TOKEN</string>
```

### 4. Required Info.plist entries
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Steddi needs your location to navigate and record routes.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Steddi needs background location access to continue navigation when the app is in the background.</string>
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>location</string>
</array>
```

## Building
1. Open Steddi.xcodeproj in Xcode (generated once project is created)
2. SPM will automatically resolve Mapbox dependencies using your .netrc credentials
3. Select your device/simulator and build
