// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cleanmoss",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CleanmossApp", targets: ["CleanmossApp"]),
        .executable(name: "cleanmoss", targets: ["cleanmoss"])
    ],
    targets: [
        .target(name: "CleanmossCore"),
        .executableTarget(name: "CleanmossApp", dependencies: ["CleanmossCore"]),
        .executableTarget(name: "cleanmoss", dependencies: ["CleanmossCore"]),
        .executableTarget(name: "CleanmossChecks", dependencies: ["CleanmossCore"], path: "Tests")
    ]
)
