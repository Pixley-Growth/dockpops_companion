# DockPops Main: Dynamic Icon Refactor Memo for Companion Support

## Purpose

This memo is for the coding agent working in the main `DockPops` app.

`DockPops Companion` now creates native per-Pop `.app` launchers called **poplets**. In `Dynamic` icon mode, the companion does **not** render Pop icons itself. It expects `DockPops` main to publish one composite PNG per Pop into the shared app-group container, then applies that PNG to the generated poplet.

The companion should also not own custom-icon editing. If DockPops supports per-Pop custom icons, the main app should render or export those through the same shared `PopIcons/<UUID>.png` contract, and the companion should stay agnostic.

The current breakage is that the main app still generates dynamic icons for its own Dock tile in memory, but it no longer reliably exports those per-Pop PNGs for the companion.

## Current Companion Contract

The companion currently depends on exactly two shared artifacts:

1. `shortcut-groups.json`
   - Source of truth for Pop identity and display names.
   - Read from `~/Library/Group Containers/group.com.dockpops.shared/shortcut-groups.json`.

2. `PopIcons/<POP_UUID>.png`
   - One PNG per Pop, named by Pop UUID.
   - Read from `~/Library/Group Containers/group.com.dockpops.shared/PopIcons/<UUID>.png`.
   - If present, the companion uses it as the poplet icon.
   - This file may represent either the standard dynamic composite or a user-chosen custom icon from DockPops main.
   - If missing, the companion falls back to the main DockPops app icon.

Relevant companion code:

- `Sources/DockPopsCompanion/Support/SharedContainerAccess.swift`
- `Sources/DockPopsCompanion/Services/PopletSyncService.swift`

Specifically:

- `PopletSyncService.sync()` reads `shortcut-groups.json`.
- `PopletSyncService.applyBestEffortIcon(...)` looks for `PopIcons/<UUID>.png`.
- The companion does not read `pops.json`.
- The companion does not read full Pop item data.
- The companion does not currently composite dynamic icons on its own.
- The companion does not own custom icon state or custom icon editing.

## Observed Regression

On the current machine state:

- `shortcut-groups.json` includes the `Games` Pop with UUID `D2B0D9C9-3B67-4005-B7D2-C1C7292258D3`.
- `PopIcons/` does **not** contain `D2B0D9C9-3B67-4005-B7D2-C1C7292258D3.png`.
- Result: the `Games` poplet falls back to the DockPops app icon instead of showing a dynamic composite.

This is not a companion bug. It is a missing export from `DockPops` main.

## Root Cause in Main App

The main app still has two separate icon responsibilities:

1. In-memory dynamic Dock icon for the main DockPops app.
2. Persistent per-Pop PNG export for external consumers like the companion.

Responsibility 1 still exists in `DockIconManager`.

Responsibility 2 is partially implemented but currently not wired correctly:

- `DockIconManager.persistCompositePNGs(store:)` still exists.
- `ShortcutSyncService.scheduleSync(...)` has the export call commented out.

Current main-app references:

- `DockPops/Services/DockIconManager.swift`
- `DockPops/Services/ShortcutSyncService.swift`
- `DockPops/Store/LauncherStore.swift`

Important detail:

Simply uncommenting the export call in `ShortcutSyncService` is probably **not enough**.

Why:

- `scheduleShortcutSync()` is triggered for add/remove/rename flows.
- Many icon-affecting changes do **not** flow through that path.
- Item edits currently go through `saveGroupItems(at:)`, which calls `DockIconManager.regenerateAndApply(...)` for in-memory updates, but does not publish the updated PNG for the companion.

So the current behavior can drift like this:

1. Pop metadata updates correctly.
2. Main Dock icon updates correctly.
3. Shared `PopIcons` stays stale or incomplete.
4. Companion shows fallback or stale poplet icons.

## What the Main App Should Do

Refactor dynamic icon support so these are treated as separate, explicit outputs:

1. **Main app Dock tile output**
   - Active Pop only.
   - In-memory.
   - Controlled by the user-facing `Dynamic Icon` toggle for the main app.

2. **Shared Pop icon export output**
   - All Pops.
   - Persistent PNGs in the app-group container.
   - Used by the companion poplets.
   - Should not depend on Shortcuts bundle mutation.
   - Should not silently stop when the main app's own Dock tile dynamic icon is disabled.

The companion architecture wants output #2 to be a stable contract.

## Recommended Refactor Direction

### 1. Keep shared Pop icon export as an explicit feature

Do not treat shared PNG export as a leftover Shortcut implementation detail.

It is now the public handoff surface for the companion.

Suggested framing:

- `shortcut-groups.json` = Pop identity contract
- `PopIcons/*.png` = Pop icon contract

### 2. Decouple export from `ShortcutSyncService`

`ShortcutSyncService` should stay focused on:

- writing `shortcut-groups.json`
- `DockPopsShortcuts.updateAppShortcutParameters()`

Do not make it the only place that updates `PopIcons`.

Instead, create a dedicated export path, for example:

- `DockIconManager.persistCompositePNG(for:group, store:)`
- `DockIconManager.persistCompositePNGs(for:groups, store:)`

or a separate `PopIconExportService`.

### 3. Trigger export on all icon-affecting changes

The companion needs fresh `PopIcons/<UUID>.png` whenever any Pop's composite would change.

That includes:

- app/file add
- app/file remove
- reorder within Pop
- sort order changes that affect visible icon order
- background color changes
- grid density changes
- Pop creation
- Pop deletion
- first launch / migration / cold start repair

Name-only changes do not require regenerating the PNG itself, but still require metadata sync.

### 4. Remove stale PNGs eagerly

When a Pop is deleted:

- remove the stale `PopIcons/<UUID>.png`
- do not wait for a future full sweep if it is easy to clean up immediately

This keeps the shared container aligned with `shortcut-groups.json`.

### 5. Keep exported PNGs raw and companion-friendly

The companion already normalizes the final icon before applying it to the poplet.

So the export should remain:

- a clean composite PNG for the Pop
- one file per Pop UUID
- stable filename

No Shortcut app mutation is needed.

## Suggested Behavioral Rules

These rules should keep the system predictable:

1. On launch:
   - write `shortcut-groups.json`
   - repair/export all current `PopIcons`
   - remove stale icon files for deleted Pops

2. On Pop metadata changes:
   - update `shortcut-groups.json`

3. On Pop content or appearance changes:
   - regenerate that Pop's composite
   - export that Pop's PNG

4. On Pop deletion:
   - remove its PNG
   - update metadata

5. On rename:
   - update metadata
   - keep the same PNG filename because the filename is UUID-based, not name-based

## Recommendation on the Main App `Dynamic Icon` Toggle

The main app's `Dynamic Icon` toggle currently controls whether the DockPops app itself shows the active Pop composite.

That should stay separate from companion support.

Recommended behavior:

- If the user turns off the main app's dynamic Dock icon, the app may stop changing `NSApp.applicationIconImage`.
- But the app should still be able to export per-Pop PNGs for the companion.

Otherwise the companion's `Dynamic` mode becomes implicitly tied to a setting that conceptually belongs only to the main DockPops Dock tile.

## Why Not Just Have the Companion Render Icons Itself?

That is possible, but only if the main app starts sharing substantially more state.

Today the companion only has:

- Pop UUID
- Pop name
- optional exported PNG

It does **not** have:

- full Pop item lists
- resolved item order
- grid density
- background color
- the compositor pipeline

So the lowest-risk path is:

- keep `DockPops` main as the single compositor
- keep `DockPops Companion` as the poplet generator / icon consumer

## Practical Implementation Suggestion

If you want the smallest safe refactor:

1. Keep `DockIconManager` as the compositor owner.
2. Add a per-group export API next to `regenerateAndApply(...)`.
3. Call that export API from the same places that already regenerate in-memory composites.
4. Add a full repair/export pass on launch.
5. Leave `ShortcutSyncService` responsible only for metadata + Shortcut registration.

This gives:

- one compositor implementation
- one shared contract for the companion
- no dependency on Shortcuts app bundle mutation
- no need for the companion to mirror DockPops rendering logic

## Acceptance Checklist

The refactor is working if all of these are true:

- Creating a new Pop writes a new `shortcut-groups.json` entry and a matching `PopIcons/<UUID>.png`.
- Renaming a Pop updates metadata but does not require a PNG rename.
- Reordering items inside a Pop updates that Pop's PNG.
- Changing a Pop background color updates that Pop's PNG.
- Deleting a Pop removes its PNG.
- Launching DockPops repairs missing PNGs for existing Pops.
- The companion shows `Games`-style Pops with proper dynamic icons instead of falling back to the DockPops app icon.

## Files to Inspect First in Main App

- `DockPops/Services/DockIconManager.swift`
- `DockPops/Services/ShortcutSyncService.swift`
- `DockPops/Store/LauncherStore.swift`
- `DockPops/Views/GeneralSettingsPane.swift`
- `DockPops/AppDelegate.swift`

## Files to Inspect First in Companion

- `/Users/etoduarte/0. Coding/Swift/3.5 DockPops Companion/Sources/DockPopsCompanion/Services/PopletSyncService.swift`
- `/Users/etoduarte/0. Coding/Swift/3.5 DockPops Companion/Sources/DockPopsCompanion/Support/SharedContainerAccess.swift`
- `/Users/etoduarte/0. Coding/Swift/3.5 DockPops Companion/Sources/DockPopsCompanion/Support/AppPaths.swift`

## Bottom Line

The companion architecture is intentionally simple:

- DockPops main owns Pop compositing.
- DockPops main publishes Pop metadata + per-Pop PNGs.
- DockPops Companion consumes those artifacts and applies them to poplets.

The refactor in the main app should make that contract explicit and reliable.
