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
            checksum: "1bd65a2b8f69ca1cab4c6058bb16783ce7017cb2b38f73917919e5e323a95921"
        ),
    ]
)
