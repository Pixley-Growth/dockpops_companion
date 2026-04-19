# DockPops Companion

Small macOS companion utility for the App Store build of DockPops.

Open `DockPopsCompanion.xcodeproj` in Xcode to build the native project directly.

Current goals:
- Read Pop metadata from `~/Library/Group Containers/group.com.dockpops.shared/shortcut-groups.json`
- Create local Poplets in `~/Applications/DockPops`
- Avoid touching signed Shortcuts bundles
- Reuse Pop icon PNGs from the shared container when they exist, otherwise fall back to the DockPops app icon

The generated Poplets are plain local `.app` bundles with a tiny native launcher that opens `dockpops://open?pop=<UUID>&locked=1`.
