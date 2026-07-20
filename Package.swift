// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DayPanel",
    platforms: [.macOS(.v14)],
    products: [
        // Apollo's production executable keeps the historical product name so
        // build.sh, packaging and Sparkle remain unchanged.
        .executable(name: "DayPanel", targets: ["DayPanel"]),
        // Shared by the production executable and the offline Apollo Studio
        // development host. Keeping the real views in one module prevents the
        // editor from drifting into a visual approximation of the app.
        .library(name: "ApolloRuntime", targets: ["ApolloRuntime"]),
    ],
    dependencies: [
        // Sparkle 2.x — secure auto-update framework. Pulled
        // in via SPM; the framework binaries land in the
        // build's bin path and `build.sh` copies them into
        // `Apollo.app/Contents/Frameworks/` so the app can
        // launch standalone.
        //
        // Setup (one-time, before publishing updates):
        //   1. Generate an EdDSA key pair with the
        //      `generate_keys` tool that ships with Sparkle.
        //   2. Drop the public key into Info.plist under
        //      `SUPublicEDKey`.
        //   3. Host an `appcast.xml` somewhere stable and
        //      point Info.plist's `SUFeedURL` at it.
        //   4. Sign each release's zip with the matching
        //      private key (`sign_update`).
        // Until those are done, the in-app "Verificar
        // Atualizações…" button still works — Sparkle just
        // logs that it can't reach a feed and tells the user
        // there are no updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Shared review engine (embedded review workflow).
        .package(path: "../apollo-review-swift"),
    ],
    targets: [
        .target(
            name: "ApolloRuntime",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "ReviewKit", package: "apollo-review-swift"),
            ],
            path: "Sources/DayPanel",
            // App bundle-only resources copied by build.sh. Excluding them
            // from SwiftPM avoids misleading "unhandled file" warnings while
            // keeping the signed bundle assembly explicit and reproducible.
            exclude: [
                "Resources/Info.plist",
                "Resources/APOLLO_ICON_06.png",
                "Resources/APOLLO.icon",
                "Resources/Apollo.entitlements",
                "Resources/SparkleEntitlements/Downloader.entitlements",
                "Resources/SparkleEntitlements/Installer.entitlements",
                "Resources/SparkleEntitlements/Updater.entitlements"
            ]
        ),
        .executableTarget(
            name: "DayPanel",
            dependencies: ["ApolloRuntime"],
            path: "Sources/DayPanelApp"
        ),
        // Invariants that were expensive to (re)discover in
        // production: deterministic task ordering, page-order
        // assembly of the parallel pagination, the causality
        // guard that protects optimistic mutations from slow
        // fetches, and the split-cache round-trip. Run with
        // `swift test`.
        .testTarget(
            name: "DayPanelTests",
            dependencies: ["ApolloRuntime"],
            path: "Tests/DayPanelTests"
        )
    ]
)
