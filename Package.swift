// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Status",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Status",
            path: "Sources/Status",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SystemConfiguration"),
            ]
        )
    ]
)
