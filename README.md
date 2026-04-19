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
2. Archive and export a notarized release build.
3. Zip the exported app with `ditto -c -k --sequesterRsrc --keepParent`.
4. Use Sparkle's `generate_appcast` tool against a folder containing your release archives.
5. Publish the generated `appcast.xml` to `docs/appcast.xml` and upload the matching archive to GitHub Releases.

The app currently defaults to manual update checks only, so Sparkle will not surprise users with a second-launch background-check permission prompt.
