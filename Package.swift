// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimLease",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SimLeaseCore", targets: ["SimLeaseCore"]),
        .library(name: "SimLeaseCLI", targets: ["SimLeaseCLI"]),
        .library(name: "SimLeaseMenuCore", targets: ["SimLeaseMenuCore"]),
        .executable(name: "simlease", targets: ["simlease"]),
        .executable(name: "SimLeaseMenuBar", targets: ["SimLeaseMenuBar"]),
    ],
    targets: [
        .target(name: "SimLeaseCore"),
        .target(name: "SimLeaseCLI", dependencies: ["SimLeaseCore"]),
        .target(name: "SimLeaseMenuCore", dependencies: ["SimLeaseCore"]),
        .executableTarget(name: "simlease", dependencies: ["SimLeaseCLI"]),
        .executableTarget(name: "SimLeaseMenuBar", dependencies: ["SimLeaseMenuCore"]),
        .testTarget(name: "SimLeaseCoreTests", dependencies: ["SimLeaseCore"]),
        .testTarget(name: "SimLeaseCLITests", dependencies: ["SimLeaseCLI", "SimLeaseCore"]),
        .testTarget(
            name: "SimLeaseMenuBarTests",
            dependencies: [
                "SimLeaseMenuBar",
                "SimLeaseMenuCore",
                "SimLeaseCore",
            ]
        ),
    ]
)
