// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchPilot",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "NotchPilot",
            path: "Sources/NotchPilot",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
    ]
)
