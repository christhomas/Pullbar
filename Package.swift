// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pullbar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "pullbar",
            path: "Sources/pullbar",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "pullbarTests",
            dependencies: ["pullbar"],
            path: "Tests/pullbarTests"
        ),
    ]
)
