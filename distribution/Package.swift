// swift-tools-version: 5.9
// Distribution manifest for the prebuilt SDK. It must live at the root of a git repository
// (SwiftPM resolves packages only from git); the binary itself is served from the CDN.
// scripts/build_xcframework.sh fills in the version and checksum.
import PackageDescription

let package = Package(
    name: "AdfactenAds",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "AdfactenAds", targets: ["AdfactenAds"]),
    ],
    targets: [
        .binaryTarget(
            name: "AdfactenAds",
            url: "https://cdn.adfacten.com/ios/AdfactenAds-1.0.2.xcframework.zip",
            checksum: "a7ce159e07b4146aa2925d9c7be76dfcda2dc4a80bd9ec4ffcef24531bc9ce7d"
        ),
    ]
)
