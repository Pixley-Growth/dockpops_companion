# DockPops Companion

Small macOS companion utility for the App Store build of DockPops.

Open `DockPopsCompanion.xcodeproj` in Xcode to build the native project directly.

Current goals:
- Read Pop metadata from `~/Library/Group Containers/group.com.dockpops.shared/shortcut-groups.json`
- Create local Poplets in `~/Applications/DockPops`
- Avoid touching signed Shortcuts bundles
- Reuse Pop icon PNGs from the shared container when they exist, otherwise fall back to the DockPops app icon

The generated Poplets are plain local `.app` bundles with a tiny native launcher that opens `dockpops://open?pop=<UUID>&locked=1`.

## Updates

The app is wired for Sparkle 2-based updates and expects its appcast at:

- `https://pixley-growth.github.io/dockpops_companion/appcast.xml`

To make that live:

1. Enable GitHub Pages for this repo and serve the `docs/` folder on `main`.
2. Build the signed release artifact with `./script/build_release.sh`.
3. Zip the exported app with `ditto -c -k --sequesterRsrc --keepParent`.
4. Use Sparkle's `generate_appcast` tool against a folder containing your release archives.
5. Publish the generated `appcast.xml` to `docs/appcast.xml` and upload the matching archive to GitHub Releases.

The app is configured for Sparkle's normal automatic update checks while still letting users trigger `Check for Updates…` manually from the app menu.

## DMG Packaging

To wrap a notarized export in a drag-to-Applications DMG:

```bash
./script/create_release_dmg.sh "/path/to/DockPopsCompanion.app"
```

That creates `release/DockPopsCompanion.dmg` containing:

- `DockPopsCompanion.app`
- an `/Applications` shortcut for the normal macOS drag-to-install flow

For the first Sparkle test cycle, you can use the menu item `Check for Updates…` after installing the first release to force a check immediately instead of waiting for Sparkle's automatic schedule.

## Release Build

For the full signed release pipeline, use:

```bash
./script/build_release.sh
```

That script:

- builds the Release app into `/tmp/DockPopsCompanion-Release`
- re-signs the embedded `DockPopsPoplet` helper with the local Developer ID identity
- re-signs the top-level app bundle and verifies both signatures
- writes the final DMG to `release/DockPopsCompanion-1.2.dmg`
