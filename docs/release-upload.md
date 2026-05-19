# Uploading A Notarized App As The Latest Release

Use this checklist when publishing a DockPops Companion DMG that is already
signed, notarized, and ready for Developer ID distribution.

## Release Shape

Publish two copies of the same final DMG asset on the GitHub release:

- `DockPopsCompanion-<version>.dmg` for Sparkle appcast entries.
- `DockPopsCompanion.dmg` for the stable `releases/latest/download` URL used by
  the README.

The GitHub release must be published, not a draft, not a prerelease, and marked
as the latest release.

## 1. Set Release Variables

```bash
VERSION=4.0
TAG="v${VERSION}"
RELEASE_DMG="release/DockPopsCompanion-${VERSION}.dmg"
LATEST_DMG="release/DockPopsCompanion.dmg"
RELEASE_NOTES="release/DockPopsCompanion-${VERSION}.md"
```

Make sure the Xcode project uses the same `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` values before building.

## 2. Build The Signed DMG

```bash
./script/build_release.sh "$RELEASE_DMG"
```

The build script creates the app, signs the embedded `DockPopsPoplet` helper,
signs the top-level app bundle, verifies both signatures, and packages the DMG.

If you intend to notarize the output from this script, verify that the
Developer ID signatures include secure timestamps. Apple notarization commonly
rejects Developer ID code signed without timestamps.

```bash
codesign -dv --verbose=4 "/tmp/DockPopsCompanion-Release/Build/Products/Release/DockPopsCompanion.app" 2>&1 \
  | rg "Authority|TeamIdentifier|Runtime|Timestamp"
```

## 3. Notarize And Staple The DMG

Submit the exact DMG that will be uploaded:

```bash
xcrun notarytool submit "$RELEASE_DMG" \
  --keychain-profile "AC_NOTARY" \
  --wait

xcrun stapler staple "$RELEASE_DMG"
xcrun stapler validate "$RELEASE_DMG"
spctl --assess --type open --verbose=4 "$RELEASE_DMG"
```

Use your existing notarytool keychain profile name if it is not `AC_NOTARY`.
Do not upload a DMG until stapler validation succeeds.

## 4. Verify The Mounted App

```bash
hdiutil attach "$RELEASE_DMG" -readonly -nobrowse

codesign --verify --strict --verbose=4 \
  "/Volumes/Install DockPopsCompanion/DockPopsCompanion.app"

codesign --verify --strict --verbose=4 \
  "/Volumes/Install DockPopsCompanion/DockPopsCompanion.app/Contents/Helpers/DockPopsPoplet"

spctl --assess --type execute --verbose=4 \
  "/Volumes/Install DockPopsCompanion/DockPopsCompanion.app"

hdiutil detach "/Volumes/Install DockPopsCompanion"
```

This confirms the uploaded installer contains the notarized app you expect, not
an older local build.

## 5. Create The Stable Latest Asset

```bash
cp -p "$RELEASE_DMG" "$LATEST_DMG"
```

Keep the versioned DMG for Sparkle. Use `DockPopsCompanion.dmg` only for the
stable GitHub latest download URL.

## 6. Regenerate The Sparkle Appcast

Use the versioned DMG URL in Sparkle so every update entry is immutable:

```bash
APPCAST_WORK="/tmp/dockpops-companion-appcast-${VERSION}"
SPARKLE_BIN="/Users/etoduarte/Library/Developer/Xcode/DerivedData/DockPopsCompanion-bwdixcextbwofzesuvaytfiolmnh/SourcePackages/artifacts/sparkle/Sparkle/bin"

rm -rf "$APPCAST_WORK"
mkdir -p "$APPCAST_WORK"
cp "$RELEASE_DMG" "$APPCAST_WORK/"
cp "$RELEASE_NOTES" "$APPCAST_WORK/"
cp docs/appcast.xml "$APPCAST_WORK/appcast.xml"

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/Pixley-Growth/dockpops_companion/releases/download/${TAG}/" \
  --embed-release-notes \
  "$APPCAST_WORK"

cp "$APPCAST_WORK/appcast.xml" docs/appcast.xml
```

Check that the new `docs/appcast.xml` entry points to
`DockPopsCompanion-<version>.dmg`, has the expected Sparkle build number, and
includes a fresh `sparkle:edSignature`.

## 7. Publish The GitHub Release

Create and push the release tag from the commit that contains the version bump,
release notes, and updated `docs/appcast.xml`:

```bash
git tag -a "$TAG" -m "DockPops Companion ${VERSION}"
git push origin "$TAG"
```

Create the release and upload both assets:

```bash
gh release create "$TAG" \
  "$RELEASE_DMG" \
  "$LATEST_DMG" \
  --title "DockPops Companion ${VERSION}" \
  --notes-file "$RELEASE_NOTES" \
  --latest \
  --verify-tag
```

If the release already exists, replace the assets only after the newly
notarized DMG has passed all validation:

```bash
gh release upload "$TAG" "$RELEASE_DMG" "$LATEST_DMG" --clobber
gh release edit "$TAG" --latest --draft=false
```

`--clobber` deletes the existing matching assets before uploading replacements,
so use it only for a verified replacement build.

## 8. Verify Public Downloads

After GitHub Pages has published `docs/appcast.xml`, verify these URLs:

- `https://github.com/Pixley-Growth/dockpops_companion/releases/latest`
- `https://github.com/Pixley-Growth/dockpops_companion/releases/latest/download/DockPopsCompanion.dmg`
- `https://pixley-growth.github.io/dockpops_companion/appcast.xml`

Download the public `DockPopsCompanion.dmg` to a clean temporary folder and run:

```bash
xcrun stapler validate "/path/to/downloaded/DockPopsCompanion.dmg"
spctl --assess --type open --verbose=4 "/path/to/downloaded/DockPopsCompanion.dmg"
```

Finally, install the app from the public DMG and use `Check for Updates...` from
the app menu to confirm Sparkle sees the new appcast entry.
