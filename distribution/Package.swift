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
            url: "https://cdn.adfacten.com/ios/AdfactenAds-1.0.0.xcframework.zip",
            checksum: "6ab9883dc8d92597f2f0c7391c4b2434c15950548e7e465e16367539290b883f"
        ),
    ]
)
