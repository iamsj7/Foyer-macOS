// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Foyer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Foyer", targets: ["Foyer"]),
        .executable(name: "checks", targets: ["checks"]),
    ],
    dependencies: [
        // mpv (LGPL build) for streams AVPlayer can't open: MKV/AVI/WebM. AVPlayer stays the default.
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.1.0-n9.0.2"),
    ],
    targets: [
        .target(name: "AddonKit"),
        .executableTarget(
            name: "Foyer",
            dependencies: ["AddonKit", .product(name: "MPVKit", package: "MPVKit")],
            linkerSettings: [
                // macOS turns on Liquid Glass for system chrome (sidebar, toolbar, controls) only when the
                // binary records SDK 26 or later. SwiftPM stamps the deployment target (14.0) as the SDK
                // version, so state the real SDK here. Deployment target stays macOS 14.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos",
                              "-Xlinker", "14.0", "-Xlinker", "27.0"]),
            ]
        ),
        .executableTarget(name: "checks", dependencies: ["AddonKit", .product(name: "MPVKit", package: "MPVKit")]),
    ]
)
