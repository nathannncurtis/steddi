# Mapbox Migration Reference

Steddi was migrated from Mapbox to MapKit + OSRM on 2026-03-24.

## What was replaced:
- **Mapbox Maps SDK** → Apple MapKit (MKMapView)
- **Mapbox Navigation SDK** → Custom NavigationEngine (Steddi/Services/NavigationEngine.swift)
- **Mapbox Directions API** → Apple MKDirections
- **Mapbox Geocoding (SearchBox v1)** → Apple MKLocalSearch
- **Mapbox Map Matching API** → OSRM public API (router.project-osrm.org)

## Why:
- Mapbox requires an on-screen logo (attribution). MapKit has zero logo requirement.
- Smaller binary (~200MB less without Mapbox SDK)
- No API token management needed

## To restore Mapbox:
1. Add to project.yml packages section:
   ```yaml
   MapboxNavigation:
     url: https://github.com/mapbox/mapbox-navigation-ios.git
     from: "3.0.0"
   ```
2. Add MBXAccessToken to Info.plist properties
3. Add ~/.netrc with Mapbox secret token for SPM download
4. Re-add package dependencies to target

## Limitations of MapKit approach:
- No speed limit data (Mapbox provided this via locationMatching stream)
- No-go zone exclusions not enforced in MKDirections (Mapbox supported exclude param)
- Map matching uses OSRM public server (rate limits possible at scale, self-host for production)
