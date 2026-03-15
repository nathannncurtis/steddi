import Foundation

/// Reads the Mapbox access token from the app bundle.
enum MapboxTokenProvider {
    static var accessToken: String {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String,
              !token.isEmpty else {
            fatalError("Mapbox access token not found. Add MBXAccessToken to Info.plist.")
        }
        return token
    }
}
