// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Steddi",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Steddi",
            targets: ["Steddi"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/mapbox/mapbox-navigation-ios.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "Steddi",
            dependencies: [
                .product(name: "MapboxNavigationCore", package: "mapbox-navigation-ios"),
                .product(name: "MapboxNavigationUIKit", package: "mapbox-navigation-ios"),
            ],
            path: "Steddi"
        ),
    ]
)
