// swift-tools-version: 6.0

import PackageDescription

// xtool builds this SwiftPM package into an iOS app. Per xtool's template, the
// app is a *library* product with an `@main` SwiftUI App inside the target.
let package = Package(
    name: "CHROMEX",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CHROMEX",
            targets: ["CHROMEX"]
        )
    ],
    targets: [
        .target(
            name: "CHROMEX",
            path: "Sources/CHROMEX",
            // Asset catalogs are compiled by Xcode; xtool bundles resources from
            // xtool.yml instead, so SwiftPM must not try to process them here.
            exclude: ["Resources"]
        )
    ]
)
