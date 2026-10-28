// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirControlHost",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AirControlHost", targets: ["AirControlHost"])
    ],
    targets: [
        .executableTarget(
            name: "AirControlHost",
            path: "Sources"
        )
    ]
)
