Pod::Spec.new do |s|
  s.name             = "AdfactenAds"
  s.version          = "1.0.0"
  s.summary          = "Adfacten Ads SDK for iOS: banner, interstitial, rewarded, native and app-open ads."
  s.homepage         = "https://github.com/adfacten/adfacten-ios-sdk"
  s.license          = { :type => "Apache-2.0", :text => "Licensed under the Apache License, Version 2.0" }
  s.author           = { "Adfacten" => "destek@adfacten.com" }
  s.platform         = :ios, "15.0"
  s.swift_versions   = ["5.9", "6.0"]
  s.source           = { :http => "https://cdn.adfacten.com/ios/AdfactenAds-#{s.version}.xcframework.zip" }
  s.vendored_frameworks = "AdfactenAds.xcframework"
  s.frameworks       = "UIKit", "WebKit", "AVFoundation", "StoreKit", "AdSupport", "AppTrackingTransparency", "Network", "SwiftUI"
end
