// swift-tools-version: 6.0
import PackageDescription

// A Swift client for Ember (https://github.com/NYLLON-SOFTWARE/ember-cloudflare), in layers
// so an app takes as much as it wants:
//
//   EmberCore      the wire shapes and the pure logic over them. No I/O.
//   EmberRichText  message bodies, read into blocks and written from what someone typed.
//   EmberSDK       the HTTP client, the two sockets and the stores an app holds. Re-exports EmberCore.
//   EmberTesting   stand-in transports and fixtures, for an app's own tests and previews.
//
// Everything builds for macOS too, so `swift test` runs on the host without a simulator.
let package = Package(
    name: "ember-swift-sdk",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "EmberCore", targets: ["EmberCore"]),
        .library(name: "EmberRichText", targets: ["EmberRichText"]),
        .library(name: "EmberSDK", targets: ["EmberSDK"]),
        .library(name: "EmberTesting", targets: ["EmberTesting"]),
    ],
    targets: [
        .target(name: "EmberCore"),
        .target(name: "EmberRichText"),
        .target(name: "EmberSDK", dependencies: ["EmberCore"]),
        .target(name: "EmberTesting", dependencies: ["EmberSDK"]),
        .testTarget(name: "EmberCoreTests", dependencies: ["EmberCore"]),
        .testTarget(name: "EmberRichTextTests", dependencies: ["EmberRichText"]),
        .testTarget(name: "EmberSDKTests", dependencies: ["EmberSDK", "EmberTesting"]),
        // Tests against a running server. They skip themselves unless EMBER_TEST_ORIGIN is set.
        .testTarget(name: "EmberLiveTests", dependencies: ["EmberSDK"]),
    ],
    swiftLanguageModes: [.v6]
)
