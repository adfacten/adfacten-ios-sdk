Pod::Spec.new do |s|
  s.name             = "AdfactenAds"
  s.version          = "1.0.0"
  s.summary          = "Adfacten Ads SDK for iOS: banner, interstitial, rewarded, native and app-open ads."
  s.homepage         = "https://github.com/adfacten/adfacten-ios-sdk"
  s.license          = { :type => "Apache-2.0", :file => "LICENSE" }
  s.author           = { "Adfacten" => "destek@adfacten.com" }
  s.platform         = :ios, "15.0"
  s.swift_versions   = ["5.9", "6.0"]
  s.source           = { :git => "https://github.com/adfacten/adfacten-ios-sdk.git", :tag => s.version.to_s }
  s.source_files     = "Sources/AdfactenAds/**/*.swift"
  s.resource_bundles = { "AdfactenAds" => ["Sources/AdfactenAds/PrivacyInfo.xcprivacy"] }
  s.frameworks       = "UIKit", "WebKit", "AVFoundation", "StoreKit", "AdSupport", "AppTrackingTransparency", "Network", "SwiftUI"
end
