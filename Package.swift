// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clipbay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clipbay",
            path: "Sources/Clipbay",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("LinkPresentation"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("Quartz"),
                .linkedFramework("WebKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
