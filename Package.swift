// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "HoloCore", targets: ["HoloCore"]),
    .executable(name: "HoloSoak", targets: ["HoloSoak"]),
    .executable(name: "HoloReplay", targets: ["HoloReplay"])
]

var targets: [Target] = [
    .target(name: "HoloCore", path: "Sources/HoloCore"),
    .executableTarget(
        name: "HoloSoak",
        dependencies: ["HoloCore"],
        path: "Sources/HoloSoak"
    ),
    .target(
        name: "HoloReplaySupport",
        dependencies: ["HoloCore"],
        path: "Sources/HoloReplaySupport"
    ),
    .executableTarget(
        name: "HoloReplay",
        dependencies: ["HoloCore", "HoloReplaySupport"],
        path: "Sources/HoloReplay"
    ),
    .testTarget(
        name: "HoloCoreTests",
        dependencies: ["HoloCore"],
        path: "Tests/HoloCoreTests"
    ),
    .testTarget(
        name: "HoloReplayTests",
        dependencies: ["HoloReplaySupport", "HoloCore"],
        path: "Tests/HoloReplayTests"
    )
]

#if os(Linux)
// Linux port: ALSA/PipeWire capture, a background service, and terminal
// workflows for calibration, evaluation, and action assignment. The macOS app
// keeps building from Holo.xcodeproj; these targets exist only on Linux.
products.append(.executable(name: "holo", targets: ["HoloLinuxCLI"]))
targets += [
    .systemLibrary(
        name: "CAlsa",
        path: "Sources/CAlsa",
        pkgConfig: "alsa",
        providers: [.apt(["libasound2-dev"])]
    ),
    .target(
        name: "HoloLinux",
        dependencies: ["HoloCore", "CAlsa"],
        path: "Sources/HoloLinux"
    ),
    .executableTarget(
        name: "HoloLinuxCLI",
        dependencies: ["HoloLinux", "HoloCore"],
        path: "Sources/HoloLinuxCLI"
    ),
    .testTarget(
        name: "HoloLinuxTests",
        dependencies: ["HoloLinux", "HoloCore"],
        path: "Tests/HoloLinuxTests"
    )
]
#endif

let package = Package(
    name: "Holo",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
