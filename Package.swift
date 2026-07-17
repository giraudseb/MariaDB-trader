// swift-tools-version: 5.10
import PackageDescription

// MariaDB Connector/C paths (Homebrew). Override with env MARIADB_PREFIX if needed.
let mariadbPrefix = "/opt/homebrew/opt/mariadb"
let mariadbLib = "\(mariadbPrefix)/lib"

let package = Package(
    name: "MariaTrader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MariaTrader", targets: ["MariaTrader"]),
        .executable(name: "smoketest", targets: ["SmokeTest"])
    ],
    targets: [
        // System module exposing MariaDB Connector/C (libmariadb) to Swift.
        // The include path lives in Sources/CMariaDB/module.modulemap
        // (absolute header path) so Xcode resolves it without -I flags.
        .systemLibrary(name: "CMariaDB"),
        // Pure Swift trading/workload engine + metrics. No UI.
        .target(
            name: "TradingCore",
            dependencies: ["CMariaDB"]
        ),
        // SwiftUI application.
        .executableTarget(
            name: "MariaTrader",
            dependencies: ["TradingCore"],
            // Asset catalog is handled by the Xcode project, not SwiftPM.
            exclude: ["Assets.xcassets"],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(mariadbLib)",
                    "-lmariadb",
                    "-Xlinker", "-rpath", "-Xlinker", "\(mariadbLib)"
                ])
            ]
        ),
        // Headless smoke-test harness (no UI) for CI / verification.
        .executableTarget(
            name: "SmokeTest",
            dependencies: ["TradingCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(mariadbLib)",
                    "-lmariadb",
                    "-Xlinker", "-rpath", "-Xlinker", "\(mariadbLib)"
                ])
            ]
        )
    ]
)
