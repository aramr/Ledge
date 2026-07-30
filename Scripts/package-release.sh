#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: ${0:t} /path/to/exported/Ledge.app [output-directory]" >&2
  exit 64
fi

ROOT="${0:A:h:h}"
APP="${1:A}"
OUTPUT_DIRECTORY="${2:-$ROOT/dist}"
OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:A}"
EXPORT_DIRECTORY="${APP:h}"
RELEASE_ROOT="${EXPORT_DIRECTORY:h}"
DSYM="${DSYM_PATH:-$RELEASE_ROOT/Ledge.xcarchive/dSYMs/Ledge.app.dSYM}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.aramrahimi.Ledge}"

[[ -d "$APP" ]] || {
  echo "Exported Ledge.app is missing from ${APP:h}" >&2
  exit 1
}
[[ "$APP" == *.app ]] || {
  echo "The release input must be an exported app bundle." >&2
  exit 1
}
[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || {
  echo "SPARKLE_PRIVATE_KEY is required." >&2
  exit 1
}

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  NOTARY_ARGUMENTS=(--keychain-profile "$NOTARYTOOL_PROFILE")
else
  [[ -f "${APPLE_API_KEY_PATH:-}" ]] || {
    echo "APPLE_API_KEY_PATH must point to an App Store Connect API key." >&2
    exit 1
  }
  [[ -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]] || {
    echo "APPLE_API_KEY_ID and APPLE_API_ISSUER_ID are required." >&2
    exit 1
  }
  NOTARY_ARGUMENTS=(
    --key "$APPLE_API_KEY_PATH"
    --key-id "$APPLE_API_KEY_ID"
    --issuer "$APPLE_API_ISSUER_ID"
  )
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ -n "$VERSION" && -n "$BUILD" ]]

ZIP="$OUTPUT_DIRECTORY/Ledge-$VERSION.zip"
DMG="$OUTPUT_DIRECTORY/Ledge-$VERSION.dmg"
DSYM_ZIP="$OUTPUT_DIRECTORY/Ledge-$VERSION-dSYM.zip"
APPCAST="$OUTPUT_DIRECTORY/appcast.xml"
CHECKSUMS="$OUTPUT_DIRECTORY/SHA256SUMS.txt"

for output in "$ZIP" "$DMG" "$DSYM_ZIP" "$APPCAST" "$CHECKSUMS"; do
  [[ ! -e "$output" ]] || {
    echo "Release output already exists: $output" >&2
    exit 1
  }
done

mkdir -p "$OUTPUT_DIRECTORY"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/LedgePackage.XXXXXX")"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

SUBMISSION_ZIP="$WORK/Ledge-notarization.zip"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$SUBMISSION_ZIP"

submit_for_notarization() {
  local submission_path="$1"
  local submission_result
  local submission_id
  local submission_status

  submission_result="$(
    xcrun notarytool submit \
      "$submission_path" \
      "${NOTARY_ARGUMENTS[@]}" \
      --wait \
      --output-format json
  )"
  submission_id="$(print -r -- "$submission_result" | jq -r '.id // empty')"
  submission_status="$(print -r -- "$submission_result" | jq -r '.status // empty')"
  print "Notarization status for ${submission_path:t}: $submission_status"

  if [[ "$submission_status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log \
        "$submission_id" \
        "${NOTARY_ARGUMENTS[@]}" \
        --output-format json >&2 || true
    fi
    return 1
  fi
}

submit_for_notarization "$SUBMISSION_ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"

if [[ -d "$DSYM" ]]; then
  ditto -c -k --keepParent --sequesterRsrc "$DSYM" "$DSYM_ZIP"
fi

DMG_ROOT="$WORK/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/Ledge.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -volname Ledge \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
submit_for_notarization "$DMG"
xcrun stapler staple "$DMG"

"$ROOT/Scripts/verify-distribution.sh" "$APP" "$DMG"

SPARKLE_BIN_DIRECTORY="${SPARKLE_BIN_DIRECTORY:-}"
if [[ -z "$SPARKLE_BIN_DIRECTORY" ]]; then
  SPARKLE_BIN_DIRECTORY="$(find "$RELEASE_ROOT/DerivedData/SourcePackages/artifacts" -type d -path '*/Sparkle/bin' -print -quit 2>/dev/null)"
fi
[[ -x "$SPARKLE_BIN_DIRECTORY/generate_appcast" ]] || {
  echo "Sparkle generate_appcast was not found; set SPARKLE_BIN_DIRECTORY." >&2
  exit 1
}

UPDATE_DIRECTORY="$WORK/updates"
mkdir -p "$UPDATE_DIRECTORY"
ditto "$ZIP" "$UPDATE_DIRECTORY/${ZIP:t}"
print -r -- "$SPARKLE_PRIVATE_KEY" | \
  "$SPARKLE_BIN_DIRECTORY/generate_appcast" \
    --account "$SPARKLE_ACCOUNT" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/aramr/Ledge/releases/download/v$VERSION/" \
    --link "https://github.com/aramr/Ledge" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    "$UPDATE_DIRECTORY"
ditto "$UPDATE_DIRECTORY/appcast.xml" "$APPCAST"

(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 "${ZIP:t}" "${DMG:t}" > "${CHECKSUMS:t}"
  if [[ -f "${DSYM_ZIP:t}" ]]; then
    shasum -a 256 "${DSYM_ZIP:t}" >> "${CHECKSUMS:t}"
  fi
  shasum -a 256 "${APPCAST:t}" >> "${CHECKSUMS:t}"
)

echo "Release artifacts created in $OUTPUT_DIRECTORY"
