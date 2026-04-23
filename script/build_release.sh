#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-/tmp/DockPopsCompanion-Release}"
OUTPUT_DMG="${1:-$ROOT_DIR/release/DockPopsCompanion-1.2.dmg}"
APP_PATH="$DERIVED_DATA/Build/Products/Release/DockPopsCompanion.app"
HELPER_PATH="$APP_PATH/Contents/Helpers/DockPopsPoplet"
APP_XCENT="$DERIVED_DATA/Build/Intermediates.noindex/DockPopsCompanion.build/Release/DockPopsCompanion.build/DockPopsCompanion.app.xcent"

resolve_developer_id_hash() {
  if [[ -n "${DEVELOPER_ID_HASH:-}" ]]; then
    printf '%s\n' "$DEVELOPER_ID_HASH"
    return
  fi

  local identity_line=""
  identity_line="$(
    security find-identity -v -p codesigning \
      | grep 'Developer ID Application: Applacat LLC (JN6FKBBBYQ)' \
      | head -n 1 || true
  )"
  if [[ -z "$identity_line" ]]; then
    identity_line="$(
      security find-identity -v -p codesigning \
        | grep 'Developer ID Application' \
        | head -n 1 || true
    )"
  fi
  if [[ -z "$identity_line" ]]; then
    echo "No Developer ID Application identity found. Set DEVELOPER_ID_HASH to override." >&2
    exit 1
  fi

  awk '{print $2}' <<<"$identity_line"
}

SIGNING_HASH="$(resolve_developer_id_hash)"

echo "Building DockPops Companion release into $DERIVED_DATA"
xcodebuild \
  -project "$ROOT_DIR/DockPopsCompanion.xcodeproj" \
  -scheme DockPopsCompanion \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app not found at $APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$HELPER_PATH" ]]; then
  echo "Embedded helper not found at $HELPER_PATH" >&2
  exit 1
fi
if [[ ! -f "$APP_XCENT" ]]; then
  echo "App entitlements not found at $APP_XCENT" >&2
  exit 1
fi

echo "Re-signing embedded helper"
/usr/bin/codesign \
  --force \
  --sign "$SIGNING_HASH" \
  -o runtime \
  --timestamp=none \
  --identifier com.dockpops.companion.poplet \
  "$HELPER_PATH"

echo "Re-signing app bundle"
/usr/bin/codesign \
  --force \
  --sign "$SIGNING_HASH" \
  -o runtime \
  --entitlements "$APP_XCENT" \
  --timestamp=none \
  --generate-entitlement-der \
  "$APP_PATH"

echo "Verifying release signatures"
/usr/bin/codesign --verify --strict --verbose=4 "$HELPER_PATH"
/usr/bin/codesign --verify --strict --verbose=4 "$APP_PATH"

echo "Building DMG at $OUTPUT_DMG"
"$ROOT_DIR/script/create_release_dmg.sh" "$APP_PATH" "$OUTPUT_DMG"

echo "Release app: $APP_PATH"
echo "Release DMG: $OUTPUT_DMG"
