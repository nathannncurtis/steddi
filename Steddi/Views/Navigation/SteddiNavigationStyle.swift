import UIKit
import MapboxNavigationUIKit
import MapboxNavigationCore
import MapboxMaps

/// Steddi's custom navigation style — soft lavender accents on warm dark surfaces.
class SteddiNightStyle: NightStyle {

    private static let lavender = UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 1.0)
    private static let lavenderLight = UIColor(red: 0.73, green: 0.68, blue: 0.87, alpha: 1.0)
    private static let warmDark = UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1.0)
    private static let warmDarkElevated = UIColor(red: 0.17, green: 0.16, blue: 0.15, alpha: 1.0)
    private static let warmWhite = UIColor(red: 0.97, green: 0.96, blue: 0.95, alpha: 1.0)
    private static let warmSecondary = UIColor(red: 0.66, green: 0.63, blue: 0.60, alpha: 1.0)

    public required init() {
        super.init()
        mapStyleURL = URL(string: StyleURI.standard.rawValue)!
        previewMapStyleURL = mapStyleURL
        styleType = .night
        statusBarStyle = .lightContent
        tintColor = Self.lavender
    }

    override open func apply() {
        super.apply()

        let tc = UITraitCollection.current

        // Top/bottom banner backgrounds — warm dark
        TopBannerView.appearance(for: tc).backgroundColor = Self.warmDark
        InstructionsBannerView.appearance(for: tc).backgroundColor = Self.warmDark
        BottomBannerView.appearance(for: tc).backgroundColor = Self.warmDark
        BottomPaddingView.appearance(for: tc).backgroundColor = Self.warmDark

        // Maneuver arrows — lavender
        ManeuverView.appearance(for: tc, whenContainedInInstancesOf: [InstructionsBannerView.self])
            .primaryColor = Self.lavenderLight
        ManeuverView.appearance(for: tc, whenContainedInInstancesOf: [InstructionsBannerView.self])
            .secondaryColor = Self.lavender.withAlphaComponent(0.4)
        ManeuverView.appearance(for: tc, whenContainedInInstancesOf: [NextBannerView.self])
            .primaryColor = Self.lavenderLight
        ManeuverView.appearance(for: tc, whenContainedInInstancesOf: [NextBannerView.self])
            .secondaryColor = Self.lavender.withAlphaComponent(0.4)

        // Labels
        PrimaryLabel.appearance(for: tc, whenContainedInInstancesOf: [InstructionsBannerView.self])
            .normalTextColor = Self.warmWhite
        DistanceLabel.appearance(for: tc, whenContainedInInstancesOf: [InstructionsBannerView.self])
            .valueTextColor = Self.warmWhite
        DistanceLabel.appearance(for: tc, whenContainedInInstancesOf: [InstructionsBannerView.self])
            .unitTextColor = Self.warmSecondary

        TimeRemainingLabel.appearance(for: tc).normalTextColor = Self.warmWhite
        TimeRemainingLabel.appearance(for: tc).trafficUnknownColor = Self.warmWhite
        DistanceRemainingLabel.appearance(for: tc).normalTextColor = Self.warmSecondary
        ArrivalTimeLabel.appearance(for: tc).normalTextColor = Self.warmSecondary

        // Next banner
        NextBannerView.appearance(for: tc).backgroundColor = Self.warmDarkElevated
        NextInstructionLabel.appearance(for: tc, whenContainedInInstancesOf: [NextBannerView.self])
            .normalTextColor = Self.warmWhite

        // Floating buttons
        FloatingButton.appearance(for: tc).backgroundColor = Self.warmDark
        FloatingButton.appearance(for: tc).tintColor = Self.lavender
        FloatingButton.appearance(for: tc).borderColor = Self.lavender.withAlphaComponent(0.2)

        // Way name
        WayNameView.appearance(for: tc).borderColor = Self.lavender.withAlphaComponent(0.3)

        // Resume
        ResumeButton.appearance(for: tc).backgroundColor = Self.warmDark
        ResumeButton.appearance(for: tc).tintColor = Self.lavender
        ResumeButton.appearance(for: tc).borderColor = Self.lavender.withAlphaComponent(0.2)

        // Navigation view background
        NavigationView.appearance(for: tc).backgroundColor = Self.warmDark

        // Cancel / dismiss
        CancelButton.appearance(for: tc).tintColor = Self.lavender
        DismissButton.appearance(for: tc).backgroundColor = Self.warmDark
        DismissButton.appearance(for: tc).textColor = Self.warmWhite

        // Lanes
        LaneView.appearance(for: tc).primaryColor = Self.lavenderLight
        LaneView.appearance(for: tc).secondaryColor = Self.warmSecondary.withAlphaComponent(0.4)
        LanesView.appearance(for: tc).backgroundColor = Self.warmDark

        // End of route
        EndOfRouteContentView.appearance(for: tc).backgroundColor = Self.warmDark
        EndOfRouteTitleLabel.appearance(for: tc).textColor = Self.warmWhite
        EndOfRouteButton.appearance(for: tc).textColor = Self.lavender

        // Separators
        SeparatorView.appearance(for: tc).backgroundColor = Self.lavender.withAlphaComponent(0.15)

        // Route line
        Task { @MainActor in
            NavigationMapView.appearance(for: tc).routeAlternateColor = Self.warmSecondary
            NavigationMapView.appearance(for: tc).routeAnnotationSelectedColor = Self.lavender
        }
    }
}

/// Steddi day style — lavender tint on default light theme.
class SteddiDayStyle: DayStyle {
    public required init() {
        super.init()
        tintColor = UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 1.0)
    }

    override open func apply() {
        super.apply()
        let tc = UITraitCollection.current
        let lavender = UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 1.0)

        ManeuverView.appearance(for: tc, whenContainedInInstancesOf: [InstructionsBannerView.self])
            .primaryColor = lavender
        FloatingButton.appearance(for: tc).tintColor = lavender
        CancelButton.appearance(for: tc).tintColor = lavender
    }
}
