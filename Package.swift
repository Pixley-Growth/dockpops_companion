// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockPopsCompanion",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "DockPopsCompanion", targets: ["DockPopsCompanion"]),
        .executable(name: "DockPopsPoplet", targets: ["DockPopsPoplet"]),
    ],
    targets: [
        .executableTarget(
            name: "DockPopsCompanion",
            path: "Sources/DockPopsCompanion"
        ),
        .executableTarget(
            name: "DockPopsPoplet",
            path: "Sources/DockPopsPoplet"
        ),
    ]
)
