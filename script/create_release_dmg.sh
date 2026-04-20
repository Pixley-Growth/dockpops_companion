#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 /path/to/DockPopsCompanion.app [/path/to/output.dmg]" >&2
  exit 2
fi

APP_PATH="$1"
APP_PATH="${APP_PATH%/}"

if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
  echo "expected a .app bundle, got: $APP_PATH" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH")"
APP_BASENAME="${APP_NAME%.app}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release"
OUTPUT_DMG="${2:-$RELEASE_DIR/${APP_BASENAME}.dmg}"
OUTPUT_DMG="${OUTPUT_DMG%/}"
BACKGROUND_SCRIPT="$ROOT_DIR/script/render_dmg_background.swift"

mkdir -p "$(dirname "$OUTPUT_DMG")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockpops-companion-dmg.XXXXXX")"
STAGING_DIR="${WORK_DIR}/staging"
RW_DMG="${WORK_DIR}/temp.dmg"
MOUNT_DIR=""
VOLUME_NAME="Install ${APP_BASENAME}"
BACKGROUND_DIR="${STAGING_DIR}/.background"
BACKGROUND_FILE="${BACKGROUND_DIR}/install-background.png"
WINDOW_LEFT=160
WINDOW_TOP=140
WINDOW_RIGHT=880
WINDOW_BOTTOM=560
APP_X=170
APP_Y=220
APPLICATIONS_X=550
APPLICATIONS_Y=220

cleanup() {
  if [[ -n "$MOUNT_DIR" ]] && mount | grep -q "on ${MOUNT_DIR} "; then
    hdiutil detach "$MOUNT_DIR" -quiet -force || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR"
mkdir -p "$BACKGROUND_DIR"
swift "$BACKGROUND_SCRIPT" "$BACKGROUND_FILE"
ditto "$APP_PATH" "${STAGING_DIR}/${APP_NAME}"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -quiet \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG"

ATTACH_OUTPUT="$(
  hdiutil attach \
    "$RW_DMG"
)"

MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' 'END { print $NF }')"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "failed to resolve mounted DMG path" >&2
  exit 1
fi

FINDER_DISK_NAME="$(basename "$MOUNT_DIR")"

osascript <<EOF
tell application "Finder"
  tell disk "$FINDER_DISK_NAME"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {$WINDOW_LEFT, $WINDOW_TOP, $WINDOW_RIGHT, $WINDOW_BOTTOM}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 14
    set background picture of viewOptions to file ".background:install-background.png"
    set position of item "$APP_NAME" to {$APP_X, $APP_Y}
    set position of item "Applications" to {$APPLICATIONS_X, $APPLICATIONS_Y}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

for _ in $(seq 1 10); do
  if [ -f "${MOUNT_DIR}/.DS_Store" ]; then
    break
  fi
  sleep 1
done

hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""

hdiutil convert \
  -quiet \
  "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$OUTPUT_DMG"

echo "Created DMG at $OUTPUT_DMG"
