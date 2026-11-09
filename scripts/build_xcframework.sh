#!/usr/bin/env bash
# Builds AdfactenAds.xcframework (iOS device arm64 + simulator arm64/x86_64), zips it, and prints the
# SwiftPM checksum. Output: dist/AdfactenAds-<version>.xcframework.zip (+ .sha256, checksum.txt).
# No upload happens here; the zip goes to https://cdn.adfacten.com/ios/ by the release process.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=$(sed -nE 's/.*sdkVersion = "([0-9.]+)".*/\1/p' Sources/AdfactenAds/Public/Adfacten.swift)
[ -n "$VERSION" ] || { echo "could not read sdkVersion"; exit 1; }
grep -q "MARKETING_VERSION = $VERSION;" Project/AdfactenAds.xcodeproj/project.pbxproj \
  || { echo "MARKETING_VERSION in the Xcode project must equal sdkVersion ($VERSION)"; exit 1; }

BUILD="${BUILD_DIR:-$ROOT/build}"
DIST="$ROOT/dist"
rm -rf "$BUILD/archives" "$DIST/AdfactenAds.xcframework"
mkdir -p "$BUILD/archives" "$DIST"

archive() { # $1 destination, $2 archive name
  xcodebuild archive -quiet \
    -project Project/AdfactenAds.xcodeproj -scheme AdfactenAds -configuration Release \
    -destination "$1" -archivePath "$BUILD/archives/$2" -derivedDataPath "$BUILD/dd" \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES
}
archive "generic/platform=iOS" ios
archive "generic/platform=iOS Simulator" ios-sim

xcodebuild -create-xcframework \
  -framework "$BUILD/archives/ios.xcarchive/Products/Library/Frameworks/AdfactenAds.framework" \
  -debug-symbols "$BUILD/archives/ios.xcarchive/dSYMs/AdfactenAds.framework.dSYM" \
  -framework "$BUILD/archives/ios-sim.xcarchive/Products/Library/Frameworks/AdfactenAds.framework" \
  -debug-symbols "$BUILD/archives/ios-sim.xcarchive/dSYMs/AdfactenAds.framework.dSYM" \
  -output "$DIST/AdfactenAds.xcframework"

# Every slice must carry the privacy manifest.
for f in "$DIST"/AdfactenAds.xcframework/*/AdfactenAds.framework; do
  [ -f "$f/PrivacyInfo.xcprivacy" ] || { echo "missing PrivacyInfo.xcprivacy in $f"; exit 1; }
done

ZIP="AdfactenAds-$VERSION.xcframework.zip"
rm -f "$DIST/$ZIP"
(cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent AdfactenAds.xcframework "$ZIP")
CHECKSUM=$(swift package compute-checksum "$DIST/$ZIP")
echo "$CHECKSUM" > "$DIST/checksum.txt"
shasum -a 256 "$DIST/$ZIP" | awk '{print $1}' > "$DIST/$ZIP.sha256"

# Fill the version/checksum into the distribution manifests.
sed -E -i '' "s|AdfactenAds-[0-9.]+\.xcframework\.zip|AdfactenAds-$VERSION.xcframework.zip|; s|checksum: \"[0-9a-f]*\"|checksum: \"$CHECKSUM\"|" distribution/Package.swift
sed -E -i '' "s|s.version( *)= \"[0-9.]+\"|s.version\1= \"$VERSION\"|" distribution/AdfactenAds.podspec

echo
echo "version : $VERSION"
echo "zip     : $DIST/$ZIP ($(du -h "$DIST/$ZIP" | cut -f1))"
echo "checksum: $CHECKSUM"
for f in "$DIST"/AdfactenAds.xcframework/*/AdfactenAds.framework/AdfactenAds; do
  echo "binary  : $(basename "$(dirname "$(dirname "$f")")") $(du -h "$f" | cut -f1) [$(lipo -archs "$f")]"
done
