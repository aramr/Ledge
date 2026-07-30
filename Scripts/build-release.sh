#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/MacDynamicIsland.xcodeproj"
OUTPUT_ROOT="${1:-$ROOT/build/release}"
OUTPUT_ROOT="${OUTPUT_ROOT:A}"
ARCHIVE_PATH="$OUTPUT_ROOT/Ledge.xcarchive"
DERIVED_DATA="$OUTPUT_ROOT/DerivedData"
EXPORT_PATH="$OUTPUT_ROOT/Export"
EXPORT_OPTIONS="$OUTPUT_ROOT/ExportOptions.plist"
TEAM_ID="${APPLE_TEAM_ID:-M7PFX75L8L}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"

if [[ -e "$ARCHIVE_PATH" || -e "$DERIVED_DATA" || -e "$EXPORT_PATH" || -e "$EXPORT_OPTIONS" ]]; then
  echo "Release build output already exists: $OUTPUT_ROOT" >&2
  exit 1
fi

mkdir -p "$OUTPUT_ROOT"

xcodebuild \
  -resolvePackageDependencies \
  -project "$PROJECT" \
  -scheme Ledge \
  -derivedDataPath "$DERIVED_DATA"

xcodebuild \
  archive \
  -project "$PROJECT" \
  -scheme Ledge \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS='--timestamp'

plutil -create xml1 "$EXPORT_OPTIONS"
plutil -insert destination -string export "$EXPORT_OPTIONS"
plutil -insert method -string developer-id "$EXPORT_OPTIONS"
plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
plutil -insert signingCertificate -string "$SIGNING_IDENTITY" "$EXPORT_OPTIONS"
plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
plutil -insert stripSwiftSymbols -bool YES "$EXPORT_OPTIONS"

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP="$EXPORT_PATH/Ledge.app"
[[ -d "$APP" ]] || {
  echo "Developer ID export did not contain Ledge.app." >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "$APP"

ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Ledge")"
[[ " $ARCHITECTURES " == *" arm64 "* ]]
[[ " $ARCHITECTURES " == *" x86_64 "* ]]

echo "Signed release archive created at $ARCHIVE_PATH"
echo "Developer ID app exported to $APP"
