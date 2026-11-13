// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DshLauncher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DshLauncher", targets: ["DshLauncherMac"])
    ],
    targets: [
        .executableTarget(
            name: "DshLauncherMac",
            path: "Sources/DshLauncherMac"
        )
    ]
)
