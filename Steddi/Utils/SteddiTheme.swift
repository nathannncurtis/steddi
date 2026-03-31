import SwiftUI
import CoreLocation

/// Steddi's visual identity — warm, steady, confident.
enum SteddiTheme {

    // MARK: - Accent Color Options

    enum AccentOption: String, CaseIterable {
        case lavender, ocean, sage, coral, gold, slate

        var color: Color {
            switch self {
            case .lavender: return Color(red: 0.61, green: 0.56, blue: 0.77)  // #9B8EC4
            case .ocean:    return Color(red: 0.29, green: 0.56, blue: 0.85)  // #4A90D9
            case .sage:     return Color(red: 0.42, green: 0.61, blue: 0.49)  // #6B9B7D
            case .coral:    return Color(red: 0.83, green: 0.45, blue: 0.42)  // #D4726A
            case .gold:     return Color(red: 0.77, green: 0.64, blue: 0.31)  // #C4A44E
            case .slate:    return Color(red: 0.48, green: 0.55, blue: 0.60)  // #7A8B9A
            }
        }

        var uiColor: UIColor {
            switch self {
            case .lavender: return UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 1.0)
            case .ocean:    return UIColor(red: 0.29, green: 0.56, blue: 0.85, alpha: 1.0)
            case .sage:     return UIColor(red: 0.42, green: 0.61, blue: 0.49, alpha: 1.0)
            case .coral:    return UIColor(red: 0.83, green: 0.45, blue: 0.42, alpha: 1.0)
            case .gold:     return UIColor(red: 0.77, green: 0.64, blue: 0.31, alpha: 1.0)
            case .slate:    return UIColor(red: 0.48, green: 0.55, blue: 0.60, alpha: 1.0)
            }
        }

        var displayName: String {
            switch self {
            case .lavender: return "Lavender"
            case .ocean:    return "Ocean Blue"
            case .sage:     return "Sage Green"
            case .coral:    return "Coral"
            case .gold:     return "Gold"
            case .slate:    return "Slate"
            }
        }
    }

    static var currentAccentOption: AccentOption {
        let raw = UserDefaults.standard.string(forKey: "accentColor") ?? AccentOption.lavender.rawValue
        return AccentOption(rawValue: raw) ?? .lavender
    }

    // MARK: - Signature Colors

    /// User-selected accent color.
    static var accent: Color { currentAccentOption.color }
    static var accentLight: Color { accent.opacity(0.7) }
    static var accentSubtle: Color { accent.opacity(0.15) }
    static var accentUIColor: UIColor { currentAccentOption.uiColor }

    /// Sage green — "all clear" / "good to go" states.
    static let sage = Color(red: 0.13, green: 0.74, blue: 0.45)         // #22BD73
    static let sageSubtle = Color(red: 0.13, green: 0.74, blue: 0.45).opacity(0.15)

    /// Soft red — warnings, delays, problems. Not alarming.
    static let warmRed = Color(red: 0.91, green: 0.30, blue: 0.24)      // #E84D3D
    static let warmRedSubtle = Color(red: 0.91, green: 0.30, blue: 0.24).opacity(0.15)

    /// Surface colors — adaptive for light/dark mode
    static let surfacePrimary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1) // warm dark
            : UIColor(red: 0.98, green: 0.97, blue: 0.96, alpha: 1) // warm white
    })
    static let surfaceSecondary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.17, green: 0.16, blue: 0.15, alpha: 1)
            : UIColor(red: 0.94, green: 0.93, blue: 0.92, alpha: 1)
    })
    static let surfaceElevated = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.22, green: 0.21, blue: 0.19, alpha: 1)
            : UIColor(red: 0.90, green: 0.89, blue: 0.88, alpha: 1)
    })

    /// Text — adaptive
    static let textPrimary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.97, green: 0.96, blue: 0.95, alpha: 1) // warm white
            : UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1) // warm dark
    })
    static let textSecondary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.66, green: 0.63, blue: 0.60, alpha: 1)
            : UIColor(red: 0.45, green: 0.43, blue: 0.41, alpha: 1)
    })
    static let textMuted = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.46, green: 0.44, blue: 0.42, alpha: 1)
            : UIColor(red: 0.60, green: 0.58, blue: 0.56, alpha: 1)
    })

    // MARK: - Typography

    /// Confident, weighted heading style
    static func heading(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    /// Body text — clean and readable
    static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    /// Mono for numbers (ETAs, times, distances)
    static func mono(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    // MARK: - Corner Radii

    static let radiusSmall: CGFloat = 10
    static let radiusMedium: CGFloat = 16
    static let radiusLarge: CGFloat = 24
    static let radiusCard: CGFloat = 20

    // MARK: - Traffic Status

    enum TrafficStatus {
        case clear, moderate, heavy, unknown

        var color: Color {
            switch self {
            case .clear: return SteddiTheme.sage
            case .moderate: return SteddiTheme.accent
            case .heavy: return SteddiTheme.warmRed
            case .unknown: return SteddiTheme.textMuted
            }
        }

        var label: String {
            switch self {
            case .clear: return "Clear"
            case .moderate: return "Moderate"
            case .heavy: return "Heavy"
            case .unknown: return "—"
            }
        }
    }
}

// MARK: - Steady Pulse Motif

/// The signature "steady line" visual — a flat, calm line that subtly pulses.
/// Used as a brand element on cards, headers, dividers.
struct SteadyLine: View {
    var color: Color = SteddiTheme.accent
    var height: CGFloat = 2
    @State private var phase: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.0), color, color, color.opacity(0.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: height)
            .mask(
                Rectangle()
                    .frame(height: height)
            )
    }
}

/// Amber-tinted glass background for Steddi's floating cards
struct SteddiCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                    .fill(SteddiTheme.surfacePrimary.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                            .stroke(SteddiTheme.accent.opacity(0.12), lineWidth: 1)
                    )
            }
    }
}

// MARK: - Theme Mode

enum ThemeMode: String, CaseIterable {
    case dark, light, dynamic

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .dynamic: return "Dynamic"
        }
    }

    /// Resolve the current color scheme based on mode and time of day
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .dynamic: return Self.isDaytime ? .light : .dark
        }
    }

    var mapInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .dynamic: return Self.isDaytime ? .light : .dark
        }
    }

    /// Calculate whether the sun is up using the user's actual location and solar math.
    /// Falls back to 7am-7pm if no location is available.
    static var isDaytime: Bool {
        // Get the user's location from LocationService or CLLocationManager
        let locManager = CLLocationManager()
        guard let coord = locManager.location?.coordinate else {
            // No location — fall back to simple time check
            let hour = Calendar.current.component(.hour, from: Date())
            return hour >= 7 && hour < 19
        }
        return sunIsUp(at: coord, date: Date())
    }

    /// Solar calculation — determines if the sun is above the horizon at a given coordinate and time.
    /// Uses UTC time + longitude to derive local solar time — independent of device timezone.
    static func sunIsUp(at coordinate: CLLocationCoordinate2D, date: Date) -> Bool {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!

        let dayOfYear = Double(utcCal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let lat = coordinate.latitude
        let lon = coordinate.longitude

        // Solar declination
        let declination = -23.44 * cos(2.0 * .pi / 365.0 * (dayOfYear + 10))

        // Hour angle at sunrise/sunset
        let latRad = lat * .pi / 180.0
        let decRad = declination * .pi / 180.0
        let cosHourAngle = -tan(latRad) * tan(decRad)

        // Handle polar day/night
        if cosHourAngle < -1 { return true }   // Midnight sun
        if cosHourAngle > 1 { return false }   // Polar night

        let hourAngle = acos(cosHourAngle) * 180.0 / .pi
        let sunriseOffset = hourAngle / 15.0  // degrees to hours

        // Local solar time from UTC + longitude (15° per hour)
        let utcHour = Double(utcCal.component(.hour, from: date)) + Double(utcCal.component(.minute, from: date)) / 60.0
        var localSolarHour = (utcHour + lon / 15.0).truncatingRemainder(dividingBy: 24.0)
        if localSolarHour < 0 { localSolarHour += 24.0 }

        let sunrise = 12.0 - sunriseOffset
        let sunset = 12.0 + sunriseOffset

        return localSolarHour >= sunrise && localSolarHour < sunset
    }
}

extension SteddiTheme {
    static var currentThemeMode: ThemeMode {
        let raw = UserDefaults.standard.string(forKey: "themeMode") ?? ThemeMode.dynamic.rawValue
        return ThemeMode(rawValue: raw) ?? .dark
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let steddiAccentColorChanged = Notification.Name("steddiAccentColorChanged")
    static let steddiThemeModeChanged = Notification.Name("steddiThemeModeChanged")
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 20) {
            SteadyLine()
                .padding(.horizontal, 40)

            SteddiCard {
                HStack {
                    Image(systemName: "house.fill")
                        .foregroundStyle(SteddiTheme.accent)
                    Text("Home")
                        .font(SteddiTheme.heading(16))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Spacer()
                    Text("12 min")
                        .font(SteddiTheme.mono(14))
                        .foregroundStyle(SteddiTheme.sage)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}
