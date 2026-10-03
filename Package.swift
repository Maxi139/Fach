// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Fach",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Fach", targets: ["FachApp"]), .library(name: "FachCore", targets: ["FachCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "FachCore", dependencies: ["CSQLite"]),
        .target(name: "FachAI", dependencies: ["FachCore"]),
        .executableTarget(name: "FachApp", dependencies: ["FachCore", "FachAI"], resources: [.process("Resources")]),
        .testTarget(name: "FachCoreTests", dependencies: ["FachCore"]),
        .testTarget(name: "FachAITests", dependencies: ["FachAI", "FachCore"])
    ]
)
