#!/usr/bin/env bash
# Builds the sample app and runs it in the iOS simulator.
#   scripts/run_sample.sh [server-url] [autodemo]
#   server-url: default http://127.0.0.1:8197 (scripts/mock_server.py); the local tracker is http://127.0.0.1:8107
#   autodemo:   interstitial | rewarded | app_open  (loads and shows that format automatically)
# Env overrides: ADF_APP_KEY, ADF_PLC_BANNER, ADF_PLC_INTERSTITIAL, ADF_PLC_REWARDED, ADF_PLC_NATIVE, ADF_PLC_APP_OPEN,
#                SIM_NAME (default "iPhone 17"), DERIVED (build dir).
set -euo pipefail
cd "$(dirname "$0")/.."
SERVER="${1:-http://127.0.0.1:8197}"
AUTODEMO="${2:-}"
SIM_NAME="${SIM_NAME:-iPhone 17}"
DERIVED="${DERIVED:-${TMPDIR:-/tmp}/adfacten-ios-sample}"

UDID=$(xcrun simctl list devices available | grep -F "    $SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$UDID" ]; then
  RUNTIME=$(xcrun simctl list runtimes | grep -E '^iOS' | tail -1 | sed -E 's/.* - (com\.apple\.CoreSimulator\.SimRuntime\.[^ ]+).*/\1/')
  DEVTYPE=$(xcrun simctl list devicetypes | grep -F "$SIM_NAME (" | head -1 | sed -E 's/.*\((com\.apple[^)]+)\).*/\1/')
  UDID=$(xcrun simctl create "$SIM_NAME" "$DEVTYPE" "$RUNTIME")
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

xcodebuild -project Project/AdfactenAds.xcodeproj -scheme AdfactenSample -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" build -quiet
APP="$DERIVED/Build/Products/Debug-iphonesimulator/AdfactenSample.app"
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" com.adfacten.sample 2>/dev/null || true

export SIMCTL_CHILD_ADF_SERVER="$SERVER"
[ -n "$AUTODEMO" ] && export SIMCTL_CHILD_ADF_AUTODEMO="$AUTODEMO"
for v in ADF_APP_KEY ADF_PLC_BANNER ADF_PLC_INTERSTITIAL ADF_PLC_REWARDED ADF_PLC_NATIVE ADF_PLC_APP_OPEN; do
  [ -n "${!v:-}" ] && export "SIMCTL_CHILD_$v=${!v}"
done
xcrun simctl launch "$UDID" com.adfacten.sample
echo "running on $UDID against $SERVER"
