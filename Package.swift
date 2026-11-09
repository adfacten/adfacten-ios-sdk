// swift-tools-version: 6.0
// Source package used by Swift Package Manager. A manifest for the prebuilt XCFramework (also on
// cdn.adfacten.com/ios) is in distribution/Package.swift.
import PackageDescription

let package = Package(
    name: "AdfactenAds",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "AdfactenAds", targets: ["AdfactenAds"]),
    ],
    targets: [
        .target(
            name: "AdfactenAds",
            path: "Sources/AdfactenAds",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "AdfactenAdsTests",
            dependencies: ["AdfactenAds"],
            path: "Tests/AdfactenAdsTests"
        ),
    ]
)
