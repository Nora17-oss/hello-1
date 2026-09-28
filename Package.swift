// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DesktopOrganizer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DesktopProbe", targets: ["DesktopProbe"]),
        .executable(name: "DesktopOrganizer", targets: ["DesktopOrganizer"])
    ],
    targets: [
        .target(name: "ProbeCore"),
        .target(name: "OrganizerCore"),
        .target(name: "OrganizerStore", dependencies: ["OrganizerCore"]),
        .executableTarget(name: "StorageSmoke", dependencies: ["OrganizerCore", "OrganizerStore"]),
        .executableTarget(name: "DesktopOrganizer", dependencies: ["OrganizerCore", "OrganizerStore", "ProbeCore"]),
        .executableTarget(name: "DesktopProbe", dependencies: ["ProbeCore"]),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"]),
        .testTarget(name: "OrganizerTests", dependencies: ["OrganizerCore", "OrganizerStore"])
    ]
)
