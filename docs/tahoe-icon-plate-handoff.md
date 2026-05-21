# Handoff: macOS 26 Tahoe white-plate on closed poplet Dock icons

**Status:** ROOT CAUSE ISOLATED; workaround implemented in recipe version 11; **healer parity completed 2026-05-21 (recipe version 13 — see "Update 2026-05-21" below)**.
**Date:** 2026-05-17

## Update 2026-05-21 — healer now mirrors the workaround on every click

`PopletBundleIconHealer.performHealIfStale` now follows the same recipe that
Companion uses at generation time:

1. clear FinderInfo + `Icon\r`
2. regenerate `AppIcon.icns` from canonical `PopIcons/<uuid>.png` (1024² master)
   via `PopletIconRendering.normalizedCanvas` (matches Companion's
   `normalizedPopletAppIcon` inset)
3. regenerate `Assets.car` via `actool` if available, else delete + clear
   `CFBundleIconName` from Info.plist
4. stamp `DockPopsIconRecipeVersion = 13` into Info.plist
5. `codesign --force --sign -`
6. **reapply Finder custom icon from canonical `.png`** (SACRED #28 revised)
7. `lsregister -f`

The healer also now fires on `applicationShouldHandleReopen`, not only cold
launch — so mid-session Pop edits reach disk on the next click instead of
waiting for next logout. Source path moved from the stale Companion mirror
to the canonical `.png` at
`~/Library/Group Containers/group.com.dockpops.shared/PopIcons/<uuid>.png`.

Recipe version bumped 11 → 13 to match the generator; future bumps will
fire the version trigger correctly because the healer now writes the version
back to Info.plist before signing.

See `docs/specs/fix-healer-to-check-canonical-on-click-every-click.md` for
the full spec and the verification status of "Path B" (Finder-custom-icon
reapply post-sign). Verification status: spec ships Path B as the design; if
a generic-folder flash is observed in practice, the spec requires
STOP-and-redesign, not silent fallback to Path A (which re-introduces the
Tahoe plate this whole document tracks).


## The bug

On macOS 26 (Tahoe), a **closed** (not running) "poplet" `.app` shows a white /
light-gray rounded-rect **plate** around its Dock icon — the real art is drawn
shrunk inside a system-drawn rounded-rect box ("icon jail" / "gray box").

- **Open** (running) poplets render fine — they set `NSApp.applicationIconImage`
  at runtime, which bypasses the static icon path.
- **Other normal apps on the same Mac do NOT show the plate.** So this is
  **specific to the poplet bundles**, not a universal Tahoe behavior. This is the
  single most important clue and it has not been explained.
- DockPops **Main** (the companion's parent app) displays Pop icons with **no
  plate**.

Poplets are runtime-generated `.app` bundles (one per "Pop"), created by the
Companion in `~/Applications/DockPops/`, with a hand-written `Info.plist`.

## Environment

- macOS 26 Tahoe. Xcode 26 (SDK `macosx26.x`).
- Companion repo: `/Users/etoduarte/0. Coding/Swift/3.5 DockPops Companion`
- DockPops Main repo: `/Users/etoduarte/0. Coding/Swift/3. DockPops`
- Poplet bundles: `~/Applications/DockPops/*.app`
- Source icon art: `~/Library/Group Containers/group.com.dockpops.shared/PopIcons/<UUID>.png`
  mirrored to `~/Library/Application Support/DockPops Companion/PopletLiveIcons/<UUID>.png`

## Facts established (with evidence)

1. **The source art is clean.** `PopIcons/<UUID>.png` is a full-bleed dark
   rounded-rect tile with app-icon thumbnails, transparent corners, **no plate**.
   Verified visually. Byte-identical to the mirrored `PopletLiveIcons` PNG.
2. **The poplet executable is built against the macOS 26 SDK** —
   `otool -l` shows `LC_BUILD_VERSION ... sdk 26.5`.
3. **Other normal apps do not plate.** Pixel-diff of a poplet icon vs
   `Calculator.app`: Calculator's `.icns` art is transparent at the edge
   midpoints (a squircle floating on a transparent canvas); the poplet's art was
   opaque at the edge midpoints (full-bleed square). This led to the "art
   geometry" theory — **which was then disproven** (see attempt 8).
4. **DockPops Main does not plate.** Its bundle has `Assets.car`,
   `CFBundleIconName`, `DT*` Info.plist keys, Developer ID signing, and a classic
   10-slot `AppIcon.appiconset` whose `Contents.json` is byte-structurally
   identical to what the Companion generates.
5. **The generated `.icns` is clean, but `NSWorkspace.icon(forFile:)` plates it.**
   Extracting `Contents/Resources/AppIcon.icns` from `Utilities 2.app` showed raw
   poplet art with no outer white/gray plate. Exporting the same bundle through
   `NSWorkspace.shared.icon(forFile:)` produced the plated icon, which isolates
   the defect to macOS' static app-icon rendering path.
6. **Finder custom icons bypass the static app-icon plate.** Applying the source
   PopIcons PNG to a temp copy with `NSWorkspace.shared.setIcon(_:forFile:)`
   made `NSWorkspace.icon(forFile:)` render clean raw artwork. This is the same
   kind of escape hatch as the running `NSApp.applicationIconImage` path.

## Everything tried — and the result

| # | Attempt | Result |
|---|---------|--------|
| 1 | Inset the baked icon by `contentScale 0.86` (no shape clip) | Plate got **bigger** (art shrank inside the fixed system plate). Reverted. |
| 2 | Crop the baked icon edge-to-edge (fill canvas) | Plate **persisted**; also made the Companion's in-app grid render icons as raw squares. Reverted. |
| 3 | Generate an `Assets.car` via `actool` (from a standard 10-slot macOS `AppIcon.appiconset`) + add `CFBundleIconName` to the poplet `Info.plist` | Plate **persisted**. (This is committed — see `c22bf38`.) |
| 4 | Remove `Assets.car` + `CFBundleIconName` — plain `.icns`-only bundle | Plate **persisted**. |
| 5 | Re-sign a poplet with a real Developer ID ("Developer ID Application: Applacat LLC (JN6FKBBBYQ)") instead of ad-hoc | Plate **persisted**. |
| 6 | Add `DT*` Info.plist keys (`DTSDKName`, `DTSDKBuild`, `DTPlatformName`, `DTPlatformVersion`, `DTXcode`, `DTXcodeBuild`, `BuildMachineOSBuild`) copied from Main | Plate **persisted**. |
| 7 | `killall Dock` (flush the Dock icon cache) | Plate **persisted**. |
| 8 | Build a properly-shaped `.icns` by hand: art inset to `824/1024` + clipped to a rounded rect (corner radius = inset edge × `0.2237`) on a transparent canvas — i.e. the *exact* transform the working open-icon path uses (`PopletIconRendering.normalizedCanvas`) — swap it in as a plain `.icns` | Plate **persisted**. This disproves the "art geometry" root cause. |
| 9 | Export `NSWorkspace.icon(forFile:)` for a generated poplet whose source PNG and extracted `.icns` are clean | Export **included the plate**. This proves IconServices / the static app-icon path is adding it. |
| 10 | Apply the source PNG as a Finder custom icon with `NSWorkspace.shared.setIcon` after bundle creation | Export rendered **clean, no plate**. This is the implemented workaround. |
| 11 | Build/export a minimal Tahoe `.icon` with Icon Composer tooling from the flat source PNG | Export gained its own glass/white enclosure treatment. Not selected. |

**Net:** ruled out — ad-hoc vs Developer ID signing; `Assets.car`/`CFBundleIconName`
presence; `DT*` keys; SDK version; icon cache; icon art geometry (square vs
inset-squircle). The trigger is the macOS static bundle-icon rendering path;
Finder custom icons bypass that path.

## What works (reference): the open-icon path

A **running** poplet sets `NSApp.applicationIconImage` from
`PopletLiveIconController`, using `PopletIconRendering.normalizedCanvas`
(inset `824/1024` + rounded-rect clip, corner radius × `0.2237`). This renders
**correctly, no plate**. Commit `ae12319`. The runtime `applicationIconImage`
path simply does not go through whatever static-icon mechanism plates the
closed bundle.

## Implemented workaround

Generated poplets now keep their clean `AppIcon.icns` / `Assets.car`, sign the
bundle, install it, then apply the same source image on a `0.86` presentation
canvas as a Finder custom icon via `NSWorkspace.shared.setIcon`. The ordering
matters: Finder custom icons are stored as `Icon\r`, resource-fork, and
`com.apple.FinderInfo` metadata, and `codesign --strict` rejects that metadata.
Applying the custom icon after signing keeps local launches working while
bypassing the Tahoe plate renderer.

The poplet self-healer now mirrors that ordering: clear any existing Finder
custom icon metadata, regenerate `AppIcon.icns`, re-sign the bundle, then
reapply the Finder custom icon and nudge Launch Services.

## Deprioritized hypotheses

- **The real macOS 26 `.icon` (Icon Composer) format.** A minimal flat `.icon`
  export was tried and added its own glass/white enclosure. A hand-authored,
  multi-layer document might still behave differently, but authoring that at
  runtime from a flat PopIcons PNG is likely impractical.
- **Launch Services classification.** Dump the poplet's LS entry:
  `lsregister -dump | grep -A40 -i 'Utilities 2'` and compare to a non-plated
  app. Maybe LS classifies the runtime-generated bundle in a way that triggers
  the fallback rendering.
- **The bundle being a runtime-generated / non-standard app** — bundle ID
  pattern (`com.dockpops.companion.poplet.<uuid>`), the `~/Applications/DockPops/`
  location, missing keys a normally-built app has, or the absence of a real
  build provenance.
- **Quarantine / `com.apple.FinderInfo` / custom-icon xattr** on the bundle.
  This became the workaround rather than the cause: setting Finder custom-icon
  metadata makes the rendered icon clean.
- **A definitive field-by-field diff** of a poplet vs a non-plated app's full
  `Info.plist`, signature, entitlements, and Mach-O — was attempted by an agent
  but did not isolate the cause; redo it exhaustively.

## State of the test specimen — IMPORTANT

`~/Applications/DockPops/Utilities 2.app` has been heavily modified by the
experiments above (Developer ID re-signed, `DT*` keys added, `Assets.car` +
`CFBundleIconName` removed, a hand-built shaped `.icns` swapped in). **Do not
trust its current state.** Regenerate it via the Companion's Refresh, or test
on a fresh poplet. The other 19 poplets are in the `c22bf38` state
(`Assets.car` + `CFBundleIconName` + full-bleed art) and all plate.

## Relevant code

`Sources/DockPopsCompanion/Services/PopletSyncService.swift`
- `writePopletBundle` — builds the poplet bundle + hand-written `Info.plist`.
- `generatedIconDataIfPossible` — bakes `AppIcon.icns` via `iconutil`.
- `generatedAssetCatalogDataIfPossible` — compiles `Assets.car` via `actool`.
- `popletIconRecipeVersion` — bump to force existing poplets to re-bake.
- `applyFinderCustomIconIfPossible` — applies the source image as a Finder
  custom icon after signing/installing, bypassing Tahoe's static app-icon plate.

`Sources/DockPopsPoplet/PopletBundleIconHealer.swift`
- `regenerateICNS` — the poplet self-heal path; re-bakes `AppIcon.icns` on launch.
- `clearFinderCustomIconIfPresent` / `applyFinderCustomIconIfPossible` — clear
  custom icon metadata before re-signing, then reapply it after signing.

`Sources/DockPopsPoplet/PopletIconRendering.swift`
- `normalizedCanvas` — the **working** open-icon transform (inset + rounded-rect clip).

`Sources/DockPopsPoplet/PopletLiveIconController.swift`
- Sets `NSApp.applicationIconImage` for the running poplet (works, no plate).

## Icon-related commits on `main`

- `a8aaf06` — first icon attempt (0.86 inset); icon part later reverted.
- `48f9cad` — revert the icon inset experiments back to as-is baking.
- `c22bf38` — Tahoe `Assets.car` + `CFBundleIconName` fix (did **not** fix the plate).
- `ae12319` — open-icon shaping in `normalizedCanvas` (this one **works** for the open icon).
