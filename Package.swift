// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "container-compose",
    platforms: [.macOS(.v14)],
    products: [
        // Exported as a library from day one. The engine is the product; the
        // CLI added later is one consumer of this, not the other way round.
        .library(name: "ComposeCore", targets: ["ComposeCore"]),
        .library(name: "ComposeEngine", targets: ["ComposeEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        // Pure: turns a compose document into an immutable Plan. No I/O, no
        // printing, no runtime access — everything it reads comes through an
        // injected FileProvider, which is what lets the whole layer be tested
        // without a container daemon.
        .target(
            name: "ComposeCore",
            dependencies: ["Yams"]
        ),
        .testTarget(
            name: "ComposeCoreTests",
            dependencies: ["ComposeCore"]
        ),

        // Executes a Plan: observes reality through a `RuntimeAdapter`, calls
        // the pure `Reconciler` in ComposeCore, executes the resulting actions,
        // and emits a typed event stream. This is the only layer that performs
        // I/O — Core stays pure, and the CLI only ever renders events.
        .target(
            name: "ComposeEngine",
            dependencies: ["ComposeCore"]
        ),
        .testTarget(
            name: "ComposeEngineTests",
            dependencies: ["ComposeEngine", "ComposeCore"]
        ),
    ]
)
