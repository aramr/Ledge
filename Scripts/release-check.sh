#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/MacDynamicIsland.xcodeproj"
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/LedgeReleaseCheck.XXXXXX")"
PROFILE_DATA="$DERIVED_DATA/ProfileData"
mkdir -p "$PROFILE_DATA"

cleanup() {
  rm -rf "$DERIVED_DATA"
}
trap cleanup EXIT

if ! git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "Release check failed: the repository has no committed revision." >&2
  exit 1
fi

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "Release check failed: commit or remove all working-tree changes first." >&2
  exit 1
fi

plutil -lint \
  "$ROOT/MacDynamicIsland/Info.plist" \
  "$ROOT/MacDynamicIsland/Ledge.entitlements" \
  "$ROOT/MacDynamicIsland/PrivacyInfo.xcprivacy"

plutil -convert json -o /dev/null \
  "$ROOT/MacDynamicIsland/Assets.xcassets/Contents.json"
plutil -convert json -o /dev/null \
  "$ROOT/MacDynamicIsland/Assets.xcassets/AppIcon.appiconset/Contents.json"

LLVM_PROFILE_FILE="$PROFILE_DATA/%p.profraw" xcodebuild \
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
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$DERIVED_DATA/Build/Products/Release/Ledge.app"
test -d "$APP"
test -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
test -f "$APP/Contents/Resources/PRIVACY.md"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Ledge")"
[[ " $ARCHITECTURES " == *" arm64 "* ]]
[[ " $ARCHITECTURES " == *" x86_64 "* ]]

# Exercise the final signing shape without requiring release-owner credentials.
# The public artifact must still be re-signed with Developer ID and notarized.
codesign \
  --force \
  --sign - \
  --options runtime \
  --entitlements "$ROOT/MacDynamicIsland/Ledge.entitlements" \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_INFO="$(codesign --display --verbose=2 "$APP" 2>&1)"
[[ "$SIGNATURE_INFO" == *"flags="*"runtime"* ]]

EMBEDDED_ENTITLEMENTS="$DERIVED_DATA/embedded-entitlements.plist"
codesign --display --entitlements :- "$APP" > "$EMBEDDED_ENTITLEMENTS" 2>/dev/null
for entitlement in \
  com.apple.security.automation.apple-events \
  com.apple.security.device.audio-input \
  com.apple.security.personal-information.calendars; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$EMBEDDED_ENTITLEMENTS")" == "true" ]]
done

FORBIDDEN_FILES="$(find "$ROOT" \
  -path "$ROOT/DerivedData" -prune -o \
  \( -name '*.profraw' -o -name '*.p12' -o -name '*.mobileprovision' \
     -o -name '*.cer' -o -name '*.key' -o -name '*.pem' -o -name '*.p8' \
     -o -name 'id_rsa' -o -name 'id_ed25519' -o -name '.env' \
     -o \( -name '.env.*' ! -name '.env.example' \) \) \
  -print)"
if [[ -n "$FORBIDDEN_FILES" ]]; then
  echo "Release check failed: generated profiling data or signing material exists in the repository." >&2
  echo "$FORBIDDEN_FILES" >&2
  exit 1
fi

echo "Release checks passed. Signing, notarization, and clean-Mac acceptance testing remain required."
