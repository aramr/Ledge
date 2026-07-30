#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/MacDynamicIsland.xcodeproj"
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/LedgeCI.XXXXXX")"

cleanup() {
  rm -rf "$DERIVED_DATA"
}
trap cleanup EXIT

plutil -lint \
  "$ROOT/MacDynamicIsland/Info.plist" \
  "$ROOT/MacDynamicIsland/Ledge.entitlements" \
  "$ROOT/MacDynamicIsland/PrivacyInfo.xcprivacy"

xcodebuild \
  -quiet \
  -resolvePackageDependencies \
  -project "$PROJECT" \
  -scheme Ledge \
  -derivedDataPath "$DERIVED_DATA"

LLVM_PROFILE_FILE="$DERIVED_DATA/%p.profraw" xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme Ledge \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ENABLE_CODE_COVERAGE=NO \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme Ledge \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$DERIVED_DATA/Build/Products/Release/Ledge.app"
[[ -d "$APP" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "com.aramrahimi.Ledge" ]]
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]

ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Ledge")"
[[ " $ARCHITECTURES " == *" arm64 "* ]]
[[ " $ARCHITECTURES " == *" x86_64 "* ]]

echo "CI checks passed."
