import UIKit
import CarPlay
import SwiftData

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    lazy var modelContainer: ModelContainer = {
        try! ModelContainer(for:
            PinnedLocation.self,
            Commute.self,
            Route.self,
            DriveRecord.self,
            NoGoZone.self,
            CommuteTrip.self,
            Report.self
        )
    }()

    let locationService = LocationService()
    let offlineCacheService = OfflineCacheService()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NSLog("[AppDelegate] didFinishLaunchingWithOptions")

        ArrivalNotificationService.shared.requestPermissionIfNeeded()
        ArrivalNotificationService.shared.registerCategory()
        ArrivalNotificationService.shared.setupDelegate()

        _ = NavigationStateManager.shared

        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        NSLog("[AppDelegate] configurationForConnecting role: %@", connectingSceneSession.role.rawValue)

        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            NSLog("[AppDelegate] → CarPlay config with delegate: CarPlaySceneDelegate")
            return config
        }

        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = PhoneSceneDelegate.self
        NSLog("[AppDelegate] → Phone config with delegate: PhoneSceneDelegate")
        return config
    }
}
