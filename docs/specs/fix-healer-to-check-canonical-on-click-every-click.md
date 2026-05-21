# Spec: Fix Healer to Check Canonical on Every Click

**Status:** Spec complete — ready for implementation
**Created:** 2026-05-21
**Revised:** 2026-05-21 (Codex review #1: corrected source to full-quality `.png`, expanded damage detection, added scripted checks)
**Revised:** 2026-05-21 (Codex review #2: normalize/inset before bake; regenerate Assets.car; stamp recipe version in Info.plist; Path B failure = stop-and-redesign)
**Owner:** Eto

## Overview
Repair the closed-bundle icon-update contract: on every click of a poplet, the poplet checks the canonical Pop composite (`PopIcons/<uuid>.png`, the 1024² full-quality master) and rewrites its own bundle if the bundle is stale or damaged. Today the contract is broken on three axes — wrong source, wrong trigger, and a strip-without-reapply path that re-introduces the Tahoe plate.

## Problem Statement
Users report poplet icons "aren't updating." After a Pop's composite changes (members added/removed in DockPops Main), the on-disk poplet bundle stays stale until next logout — and even after a heal, the closed/at-rest Dock tile shows a Tahoe-plated icon.

Root causes:

1. **Healer reads the stale Companion mirror.** `Sources/DockPopsPoplet/PopletBundleIconHealer.swift:44` reads `PopletSharedPaths.mirroredPopIconURL(...)` at `~/Library/Application Support/DockPops Companion/PopletLiveIcons/<uuid>.png`. The mirror is only fresh while Companion runs, but Companion is a regular foreground app and is closed most of the time.
2. **Healer only fires on cold launch.** `applicationDidFinishLaunching` (`Sources/DockPopsPoplet/DockPopsPopletMain.swift:107`) calls `healIfStale()`. `applicationShouldHandleReopen` (line 120) does not. Poplets are `.accessory` + resident, so once the first click of a session has happened, every subsequent click is a reopen and the bundle never gets re-checked.
3. **Healer strips Finder custom icon and never reapplies.** `clearFinderCustomIconIfPresent` at line 72; the matching `applyFinderCustomIconIfPossible(from:)` at line 208 exists but is never called. Per `docs/tahoe-icon-plate-handoff.md`, the Finder custom icon is the load-bearing escape hatch from macOS' static app-icon rendering path that adds the Tahoe plate around runtime-generated bundles.

## Canonical-source clarification

DockPops Main writes two files per Pop into `~/Library/Group Containers/group.com.dockpops.shared/PopIcons/`:

| File | Resolution | Purpose | Reader |
|---|---|---|---|
| `<uuid>.png` | 1024² | Full-quality composite **master**. The canonical source for bundle repair (iconutil needs to fill 1024² slots). | **Healer** (this spec) + `PopletSyncService` |
| `<uuid>.live.png` | 256² | Derived runtime variant for `applicationIconImage`. Smaller/faster for polling. | `PopletLiveIconController` |

The healer must read `.png`, not `.live.png`. Upscaling 256→1024 inside `iconutil` would visibly degrade the rendered ICNS. The Companion already does it right (`PopletSyncService.swift:438`).

## Contract
**On every click → poplet checks whether the bundle needs healing → if so, rewrites the bundle in place from the canonical `.png`.**

"Needs healing" is true if any of:
- Canonical `.png` is newer than the bundle's `AppIcon.icns`
- Bundle's stored `DockPopsIconRecipeVersion` doesn't match the current healer version
- `Contents/Resources/AppIcon.icns` is missing
- `Contents/Icon\r` (Finder custom icon resource) is missing
- `com.apple.FinderInfo` xattr is missing or its `kHasCustomIcon` bit is unset

The last two cover bundles damaged by 4.1 (icns timestamps look current but Finder custom icon was stripped).

## Scope

### In Scope
- Wire `healIfStale()` into `applicationShouldHandleReopen` so it fires on every click, not only cold launch.
- Change healer source from Companion mirror to canonical `~/Library/Group Containers/group.com.dockpops.shared/PopIcons/<uuid>.png` (the 1024² master).
- Implement Path B in the healer: strip existing Finder custom icon metadata → normalize canonical `.png` via `PopletIconRendering.normalizedCanvas(from:)` → rewrite `AppIcon.icns` from normalized image → regenerate or remove `Assets.car` (see below) → stamp `DockPopsIconRecipeVersion` into Info.plist → sign clean → reapply Finder custom icon from canonical. Matches `PopletSyncService.swift:341`'s `normalizedPopletAppIcon()` + bake pipeline.
- Bump `PopletBundleIconHealer.iconRecipeVersion` from 11 to 13 to match `PopletSyncService.popletIconRecipeVersion`. Also **write back** to the bundle's `Info.plist` after a successful heal so the recipe-version trigger doesn't fire on next click.
- Handle `Assets.car` during heal: if `actool` is available (Xcode/CLT present), regenerate via the same path Companion uses (`generatedAssetCatalogDataIfPossible`). If `actool` unavailable (typical on end-user machines without Xcode), delete `Contents/Resources/Assets.car` and remove the `CFBundleIconName` key from Info.plist so LaunchServices falls back to the fresh `AppIcon.icns`. Either branch results in a non-stale closed-tile rendering.
- Rename `sourceIsNewer` → `bundleNeedsHeal` (or equivalent) and broaden it to the five-trigger check above. This is what makes the "repair existing damaged bundles on first click" promise actually fire.
- Revise SACRED ZONE #28 (`PopletBundleIconHealer.swift:75–107`) to document Path B and the flash verification result.
- Update `PopletSharedPaths.swift` SACRED docstring (lines 27–60) to reflect that the mirror is Companion-internal, not the poplet's source of truth.

### Out of Scope
- Cross-repo changes in DockPops Main (Codex's recommended structurally cleaner architecture — Main owning static bundle writes — is a separate project).
- Changes to `PopletSyncService.applyFinderCustomIconIfPossible(_:to:)` at `PopletSyncService.swift:411` (kept as-is; healer aligns to its existing approach).
- Removing or rewriting the Companion's `PopletLiveIconMirror` writer.
- Stored source fingerprint/hash in Info.plist (Codex P2). Could be added later as a stronger damage signal; not blocking this fix.
- New IPC mechanisms between Main and Companion.
- A background helper / login-item agent.
- Sparkle / auto-update flow.
- Companion-side UI changes.

## User Stories

### US-1: Healer reads canonical `.png` and triggers on every click
**Description:** As a user, when I change a Pop's members and then click that poplet's Dock icon, the bundle on disk should be updated with the new composite icon — regardless of whether Companion is running, and including repair of bundles damaged by 4.1.

**Acceptance Criteria:**
- [ ] `PopletBundleIconHealer.sourcePNG` resolves to `~/Library/Group Containers/group.com.dockpops.shared/PopIcons/<uuid>.png` (1024² master), **not** the Companion mirror and **not** `.live.png`.
- [ ] `DockPopsPopletMain.applicationShouldHandleReopen` kicks off `Task.detached(priority: .utility) { await healer.healIfStale() }` after `refreshFromSharedContainer()`, before `openPop()`.
- [ ] `PopletBundleIconHealer.iconRecipeVersion = 13` (matches generator).
- [ ] `bundleNeedsHeal(...)` returns true if any of: source newer than ICNS, recipe version mismatch, `AppIcon.icns` missing, `Contents/Icon\r` missing, OR `com.apple.FinderInfo` xattr missing/kHasCustomIcon bit unset.
- [ ] After a successful heal, the bundle's Info.plist contains `DockPopsIconRecipeVersion = 13`. (Write-back before signing.) Subsequent clicks with no canonical change do NOT trigger a heal on the version criterion.
- [ ] `regenerateICNS` loads the canonical `.png`, runs it through `PopletIconRendering.normalizedCanvas(from:)`, then bakes iconset variants from the normalized canvas — matching `PopletSyncService.swift:341`'s `normalizedPopletAppIcon()` pipeline. Raw full-bleed bake is rejected.
- [ ] Heal handles `Assets.car`: if `actool` available, regenerate using the normalized canvas; if not, delete `Assets.car` and remove `CFBundleIconName` from Info.plist before signing.
- [ ] When canonical `.png` is missing, healer logs once at info level and returns without modifying the bundle.
- [ ] After bringing a healthy poplet to v13 by one heal, subsequent clicks where nothing has changed do **not** rewrite the bundle (all four checks short-circuit).
- [ ] A bundle damaged by 4.1 (FinderInfo stripped, ICNS timestamp fresh) IS rewritten on first click after the fix ships, even though timestamp alone wouldn't flag it.
- [ ] Existing flock-based `BundleLockHandle` serializes overlapping heals from rapid double-clicks; no race conditions observed in manual click-spam testing.

### US-2: Healer applies Finder custom icon (Path B) and verification confirms no flash
**Description:** As a user, the closed/at-rest poplet Dock tile and Finder view should show the current Pop composite without the Tahoe white plate, and clicking the poplet should not show a generic-folder blink.

**Acceptance Criteria:**
- [ ] `performHealIfStale` sequence: `clearFinderCustomIconIfPresent` → `regenerateICNS` → `signBundle` → `applyFinderCustomIconIfPossible(from: sourcePNG)` → `registerWithLaunchServices`.
- [ ] The `applyFinderCustomIconIfPossible(from:)` function at line 208 is called from this sequence (no longer dead code).
- [ ] Manual visual verification: click a damaged poplet 10+ times in rapid succession on the developer machine; record observed behavior in the implementation PR. Acceptance: no generic-folder blink visible on any click.
- [ ] Scripted post-heal sanity check (see Phase 2 verification): `Contents/Icon\r` exists, `com.apple.FinderInfo` xattr exists, and `codesign --verify --strict` output is captured for the record. Strict-verify is allowed to fail (FinderInfo expected to invalidate strict signing); the result is informational, not a gate.
- [ ] **If a blink IS visible: STOP. Do not silently fall back to Path A.** Path A re-introduces the Tahoe plate, which contradicts this story's goal. Treat visible-blink as a redesign trigger — investigate alternative codesign flags (`--preserve-metadata`?), a non-`NSWorkspace.setIcon` Finder-custom-icon mechanism, or escalate to a structural fix (e.g., DockPops Main owning bundle writes). Document the investigation in the spec's Implementation Notes section and pause shipping until resolved.
- [ ] After a heal, opening Finder at `~/Applications/DockPops/` shows the freshly composited icon on the bundle, no Tahoe plate.
- [ ] After a logout/login cycle, the closed Dock tiles show the freshly composited icon, no Tahoe plate (assuming the poplet was clicked at least once in the prior session).

### US-3: SACRED zones and shared-path docstrings updated to match new behavior
**Description:** As a future maintainer, when I read the inline SACRED comments around the healer, they should accurately describe the current Path B strategy and reference the verification that established it — not the prior Path A reasoning.

**Acceptance Criteria:**
- [ ] `PopletBundleIconHealer.swift:75–107` SACRED ZONE #28 is rewritten to document: (a) the click-time check-and-rewrite contract, (b) why we now reapply Finder custom icon (Tahoe plate workaround), (c) the flash verification result from US-2, (d) why `.png` is the source rather than `.live.png`.
- [ ] If the verification ended up falling back to Path A, the SACRED comment instead documents Path A and why (no reapply, Tahoe plate accepted).
- [ ] `PopletSharedPaths.swift:27–60` SACRED docstring is updated to clarify that the mirror is a Companion-internal cache, not the poplet's source of truth. Assertions remain (other callers may still read the mirror); only the explanatory text changes.
- [ ] `docs/tahoe-icon-plate-handoff.md` is updated with a final dated note: "2026-05-21: healer now follows the documented recipe (strip → regenerate → sign → reapply) from canonical `.png`; flash verified absent on every-click trigger."

## Technical Design

### Data flow (after fix)

```
Main edits Pop members
       │
       ▼
Main writes PopIcons/<uuid>.png (1024², master)
                 + PopIcons/<uuid>.live.png (256², derived)
       │
       ▼ (DNC iconUpdated)
Running poplet's PopletLiveIconController reads .live.png
   → updates applicationIconImage (in-memory tile)
       │
User clicks Dock tile (reopen)
       │
       ▼
applicationShouldHandleReopen:
  1. refreshFromSharedContainer (poll .live.png for in-memory tile)
  2. Task.detached { healer.healIfStale() }   ←── NEW
  3. openPop()
       │
       ▼ (in background)
healer.healIfStale reads canonical .png (1024² master)
       │
       ▼ (if bundleNeedsHeal returns true)
  clear FinderInfo / Icon\r
  → normalizedCanvas(from: rawImage)        ←── NEW (inset + rounded-rect)
  → regenerate AppIcon.icns from normalized
  → regenerate Assets.car via actool        ←── NEW (or delete + clear CFBundleIconName)
  → write DockPopsIconRecipeVersion=13 to   ←── NEW (so version trigger doesn't refire)
       Info.plist
  → codesign --force --sign - <bundle>
  → setIcon (reapply Finder custom icon from .png)
  → lsregister -f
```

### Files touched

| File | Change |
|---|---|
| `Sources/DockPopsPoplet/PopletBundleIconHealer.swift` | `sourcePNG` reads canonical `.png` path; `iconRecipeVersion = 13`; `sourceIsNewer` replaced by broader `bundleNeedsHeal`; `regenerateICNS` normalizes via `PopletIconRendering.normalizedCanvas` before bake; new `regenerateOrRemoveAssetsCar` step; new `stampRecipeVersionInInfoPlist` step before signing; `performHealIfStale` calls `applyFinderCustomIconIfPossible(from:)` after sign; SACRED #28 rewrite |
| `Sources/DockPopsPoplet/DockPopsPopletMain.swift` | `applicationShouldHandleReopen` gains the `Task.detached { healer.healIfStale() }` between `refreshFromSharedContainer` and `openPop` |
| `Sources/DockPopsPoplet/PopletSharedPaths.swift` | SACRED docstring update (no logic change) |
| `docs/tahoe-icon-plate-handoff.md` | Append dated status note |

### Healer source path

Replace:
```swift
self.sourcePNG = PopletSharedPaths.mirroredPopIconURL(for: popID)
```

with the canonical 1024² master (same directory `PopletLiveIconController.sharedPopIconDirectory` uses at `PopletLiveIconController.swift:188`, but with `.png` not `.live.png`):

```swift
self.sourcePNG = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Group Containers/group.com.dockpops.shared", directoryHint: .isDirectory)
    .appending(path: "PopIcons", directoryHint: .isDirectory)
    .appending(path: "\(popID.uuidString).png")
```

Drop the `PopletSharedPaths.assertUsesMirroredLiveIconFile` precondition since this path is intentionally outside the mirror. Consider extracting the shared directory URL into a single static accessor reused by both the healer and `PopletLiveIconController` — they share the directory, differ only in filename.

### Broader damage detection (`bundleNeedsHeal`)

Replace `sourceIsNewer(source:target:)` with:

```swift
private func bundleNeedsHeal(source: URL, target: URL) throws -> Bool {
    // Trigger 1: stored recipe version doesn't match this healer.
    if storedIconRecipeVersion() != Self.iconRecipeVersion {
        return true
    }
    // Trigger 2: target ICNS missing entirely.
    guard FileManager.default.fileExists(atPath: target.path) else {
        return true
    }
    // Trigger 3: source newer than target.
    let sourceDate = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let targetDate = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    if let sourceDate, let targetDate, sourceDate > targetDate {
        return true
    }
    // Trigger 4: Finder custom icon resource (Icon\r) missing — bundle damaged.
    let iconResourceURL = bundleURL.appending(path: "Icon\r")
    if !FileManager.default.fileExists(atPath: iconResourceURL.path) {
        return true
    }
    // Trigger 5: FinderInfo xattr missing — bundle damaged.
    if !hasFinderCustomIconAttribute(bundleURL: bundleURL) {
        return true
    }
    return false
}

private func hasFinderCustomIconAttribute(bundleURL: URL) -> Bool {
    bundleURL.withUnsafeFileSystemRepresentation { path in
        guard let path else { return false }
        let size = Darwin.getxattr(path, "com.apple.FinderInfo", nil, 0, 0, 0)
        return size > 0
    }
}
```

(Implementation may also inspect `kHasCustomIcon` bit; simplest first cut is "xattr present at all," since the healer's own `clearFinderCustomIconIfPresent` removes the whole xattr.)

### Path B sequence in performHealIfStale

```swift
private func performHealIfStale() async throws {
    guard let sourcePNG else { return }
    guard FileManager.default.fileExists(atPath: sourcePNG.path) else {
        Self.logger.info("canonical missing for \(bundleURL.lastPathComponent, privacy: .public)")
        return
    }
    let targetICNS = bundleURL
        .appending(path: "Contents", directoryHint: .isDirectory)
        .appending(path: "Resources", directoryHint: .isDirectory)
        .appending(path: "\(Self.iconName).icns")

    guard try bundleNeedsHeal(source: sourcePNG, target: targetICNS) else { return }

    try await clearFinderCustomIconIfPresent()
    try regenerateICNS(from: sourcePNG, to: targetICNS)        // normalizes internally
    try regenerateOrRemoveAssetsCar(from: sourcePNG)           // NEW
    try stampRecipeVersionInInfoPlist()                         // NEW
    try signBundle(at: bundleURL)
    await applyFinderCustomIconIfPossible(from: sourcePNG)     // Path B reapply
    registerWithLaunchServices(bundleURL: bundleURL)
    Self.logger.info("icon healed for \(bundleURL.lastPathComponent, privacy: .public)")
}
```

### Normalize before bake (regenerateICNS)

```swift
private func regenerateICNS(from pngURL: URL, to icnsURL: URL) throws {
    guard let rawImage = PopletIconRendering.loadImage(at: pngURL) else {
        throw PopletIconError.imageLoadFailed(pngURL)
    }
    // SACRED: Companion bakes the icns from the normalized/inset canvas
    // (PopletSyncService:341 normalizedPopletAppIcon). The healer must match
    // or the rebaked ICNS will be full-bleed and the closed Dock tile will
    // be ~15% oversized vs sibling icons (regression 48f9cad).
    guard let normalized = PopletIconRendering.normalizedCanvas(from: rawImage) else {
        throw PopletIconError.imageLoadFailed(pngURL)
    }
    // ... existing iconset variant loop, but use `normalized` instead of `rawImage`
}
```

### Assets.car handling (regenerateOrRemoveAssetsCar)

```swift
private func regenerateOrRemoveAssetsCar(from pngURL: URL) throws {
    let resourcesURL = bundleURL
        .appending(path: "Contents", directoryHint: .isDirectory)
        .appending(path: "Resources", directoryHint: .isDirectory)
    let assetCatalogURL = resourcesURL.appending(path: "Assets.car")

    if let actoolURL = locateActool() {
        // Regenerate via actool (mirrors PopletSyncService.generatedAssetCatalogDataIfPossible)
        let newData = try compileAssetsCarUsingActool(actoolURL: actoolURL, sourcePNG: pngURL)
        try newData.write(to: assetCatalogURL, options: .atomic)
        // Info.plist CFBundleIconName already set by Companion at generation; leave it.
    } else {
        // actool unavailable (typical end-user machine). Remove Assets.car
        // and clear CFBundleIconName so LaunchServices uses the fresh AppIcon.icns.
        if FileManager.default.fileExists(atPath: assetCatalogURL.path) {
            try FileManager.default.removeItem(at: assetCatalogURL)
        }
        try clearInfoPlistKey("CFBundleIconName")
    }
}
```

### Recipe-version write-back (stampRecipeVersionInInfoPlist)

```swift
private func stampRecipeVersionInInfoPlist() throws {
    let infoPlistURL = bundleURL
        .appending(path: "Contents", directoryHint: .isDirectory)
        .appending(path: "Info.plist")
    let data = try Data(contentsOf: infoPlistURL)
    var format = PropertyListSerialization.PropertyListFormat.xml
    guard var plist = try PropertyListSerialization.propertyList(
        from: data, options: [], format: &format
    ) as? [String: Any] else {
        throw PopletIconError.imageLoadFailed(infoPlistURL)
    }
    plist[Self.iconRecipeVersionInfoKey] = Self.iconRecipeVersion
    let outData = try PropertyListSerialization.data(
        fromPropertyList: plist, format: format, options: 0
    )
    try outData.write(to: infoPlistURL, options: .atomic)
}
```

Must run **before** `signBundle` so the signature covers the updated Info.plist. (`clearInfoPlistKey` in the previous block follows the same pattern.)

### Reopen wiring

```swift
func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    liveIconController?.refreshFromSharedContainer()

    if let popID = UUID(uuidString: rawPopID) {
        let healer = PopletBundleIconHealer(popID: popID, bundleURL: Bundle.main.bundleURL)
        Task.detached(priority: .utility) {
            await healer.healIfStale()
        }
    }

    openPop()
    return false
}
```

## Non-Functional Requirements

- **NFR-1 (latency):** Click → popover open time unchanged from current baseline. Heal runs detached so it doesn't block the popover.
- **NFR-2 (concurrency):** Rapid double-clicks must not corrupt the bundle. Existing flock-based `BundleLockHandle` is sufficient; second heal blocks until first finishes, then short-circuits via `bundleNeedsHeal`.
- **NFR-3 (no flash):** Manually verified at implementation time. **If verification fails, STOP and redesign** — Path A is not an acceptable fallback because it re-introduces the Tahoe plate that US-2 explicitly rules out.
- **NFR-4 (idempotence):** Repeated heals with no canonical change AND no bundle damage must be no-ops (all five `bundleNeedsHeal` triggers return false).

## Implementation Phases

### Phase 1 — Source + trigger + broader damage detection + normalize + Assets.car + recipe stamp
- [ ] Change `PopletBundleIconHealer.sourcePNG` to canonical `.png` (1024² master). Remove mirror assertion in the constructor.
- [ ] Bump `iconRecipeVersion` to 13.
- [ ] Replace `sourceIsNewer` with `bundleNeedsHeal` (5 triggers: recipe mismatch, missing ICNS, source newer, missing Icon\r, missing FinderInfo).
- [ ] Update `regenerateICNS` to call `PopletIconRendering.normalizedCanvas(from:)` before baking iconset variants. Reject the raw full-bleed bake path.
- [ ] Add `regenerateOrRemoveAssetsCar(from:)`: if `actool` available, regenerate; if not, delete `Assets.car` and clear `CFBundleIconName` from Info.plist.
- [ ] Add `stampRecipeVersionInInfoPlist()`: write `DockPopsIconRecipeVersion = 13` to bundle's Info.plist. Must run before `signBundle`.
- [ ] Wire `healer.healIfStale()` into `applicationShouldHandleReopen` after `refreshFromSharedContainer`, before `openPop`.
- [ ] Build, verify no compile errors.
- **Verification:**
  - Build Companion from Xcode.
  - Launch a damaged poplet (one with `xattr -c <bundle>` already run, or Assets.car/AppIcon.icns out of date). Confirm via Console.app logs that the healer runs.
  - After heal completes: `xattr -l ~/Applications/DockPops/<Name>.app` lists `com.apple.FinderInfo`; `ls ~/Applications/DockPops/<Name>.app/Icon?` finds the `Icon\r` file.
  - Confirm bundle's `AppIcon.icns` mtime is now ≥ canonical `~/Library/Group Containers/group.com.dockpops.shared/PopIcons/<uuid>.png` mtime.
  - Confirm bundle's Info.plist `DockPopsIconRecipeVersion = 13` via `/usr/libexec/PlistBuddy -c "Print :DockPopsIconRecipeVersion" <Contents/Info.plist>`.
  - On dev machine (actool present): `ls -la ~/Applications/DockPops/<Name>.app/Contents/Resources/Assets.car` shows a fresh mtime. On non-Xcode machine: Assets.car absent + `CFBundleIconName` removed from Info.plist.
  - Click the same poplet a second time without changing anything: heal logs at debug level only and does NOT rewrite (`bundleNeedsHeal` returns false on all 5 triggers).

### Phase 2 — Path B reapply + flash verification
- [ ] Add `await applyFinderCustomIconIfPossible(from: sourcePNG)` call in `performHealIfStale` between `signBundle` and `registerWithLaunchServices`.
- [ ] Manual visual check: damage a poplet (`xattr -c <bundle>`; remove `Icon?`), click it 10+ times rapidly, observe Dock tile. Acceptance: no generic-folder blink on any click.
- [ ] Scripted post-heal sanity check (capture in PR):
  ```bash
  BUNDLE=~/Applications/DockPops/<Name>.app
  ls "$BUNDLE"/Icon? && echo "OK: Icon\\r present"
  xattr -l "$BUNDLE" | grep com.apple.FinderInfo && echo "OK: FinderInfo present"
  codesign --verify --strict "$BUNDLE" 2>&1 | tee /tmp/codesign-strict.log
  # --strict expected to fail with "Disallowed xattr"; informational only
  ```
- [ ] If a blink IS visible OR scripted check fails (Icon\r / FinderInfo missing post-heal): **STOP**. Do not fall back to Path A. Path A re-introduces the Tahoe plate, which contradicts US-2's goal. Document the failure mode + investigation paths in Implementation Notes (alternative codesign flags, alternative custom-icon mechanism, or escalation to a structural fix), and pause shipping until resolved.
- [ ] After verification: confirm closed Dock tile (after logout/login or `killall -9 DockPopsPoplet`) shows fresh composite with no Tahoe plate.
- **Verification:** Visual inspection on developer machine + scripted post-heal artifact assertions. Document findings in PR description and in this spec's Implementation Notes section.

### Phase 3 — SACRED + docs cleanup
- [ ] Rewrite `PopletBundleIconHealer.swift:75–107` SACRED ZONE #28 to reflect actual final behavior (B or fallback A), including why `.png` is the source.
- [ ] Update `PopletSharedPaths.swift:27–60` SACRED docstring to clarify mirror is Companion-internal.
- [ ] Append a dated status note to `docs/tahoe-icon-plate-handoff.md`.
- **Verification:** Read the comments fresh; do they describe the current code's actual behavior accurately to someone new?

## Definition of Done

- [ ] All three user stories' acceptance criteria pass on the developer machine.
- [ ] Build succeeds: Xcode build from `DockPopsCompanion.xcodeproj`.
- [ ] Manual end-to-end test: edit a Pop in DockPops Main while poplets are running; click the affected poplet; verify the on-disk `AppIcon.icns` is updated within a few seconds; verify Finder shows the new icon on the bundle; logout/login and verify closed Dock tile shows the new icon without Tahoe plate.
- [ ] Scripted post-heal check (Icon\r + FinderInfo presence) passes on a previously-damaged bundle.
- [ ] `codesign --verify --strict` output captured (pass-or-fail is informational; the spec accepts Path B's invalidated strict signature in exchange for no Tahoe plate).
- [ ] PR includes screenshot or short screen recording of the flash verification result.
- [ ] SACRED comments and handoff doc reflect the actual implemented behavior.

## Open Questions / Risks

- **Risk 1 (Codex P1):** Path B's `setIcon` after sign leaves the bundle's signature invalid under `--strict`. Companion does this today at generation time without observable issues. The healer-time risk is that invalidation happens repeatedly across a poplet's lifetime (vs. once at generation), which may trigger different LaunchServices behavior. Phase 2 verification covers this; scripted check captures `codesign --verify --strict` output as evidence.
- **Risk 2:** If the canonical `.png` is written non-atomically by Main (e.g., truncate-then-write), the healer could read a half-written file. Not observed today, but worth a `try?` guard. Skipping a heal on a corrupt read is acceptable per US-1.
- **Risk 3:** Adding heal to every reopen multiplies codesign invocations. With `bundleNeedsHeal` short-circuiting when nothing has changed, the steady-state cost is just a few stat calls + one getxattr. Only actual icon changes (or damage) trigger codesign. Acceptable per NFR-1 (detached); revisit if real users see CPU/battery impact.
- **Risk 4:** The flash diagnosis in commit `7ca31d0` may have been accurate for a different ordering than what we have now. If Phase 2 verification confirms no flash, the original SACRED #28 was over-strong; if it confirms flash, the design needs another pass.
- **Risk 5 (Codex P1/P2):** This fix is "repair on next click," not "self-update while closed." Closed Dock tiles update lazily when the user next interacts with each poplet. Codex's structurally cleaner alternative — DockPops Main owning static bundle writes — is deferred to a future project. If users complain about closed-tile latency in normal use, revisit.
- **Risk 6 (Codex P2):** `bundleNeedsHeal` triggers on file presence, not content hash. A bundle with the right files but wrong content (e.g., a corrupted `Icon\r`) wouldn't be detected. Adding a stored source fingerprint in Info.plist would close this gap; deferred as a strengthening pass.
- **Risk 7 (Codex review #2):** `actool` is bundled with Xcode and is typically absent on end-user machines. The healer's Assets.car path therefore needs both branches (regenerate when actool present; delete + clear `CFBundleIconName` when absent). The delete path is the "normal" code path on end-user machines; the regenerate path is mainly for development.
- **Risk 8 (Codex review #2):** Writing `DockPopsIconRecipeVersion` to Info.plist before signing means the Info.plist is touched on every heal that fires. Acceptable: it's tiny, atomic, and covered by codesign. The alternative (write after signing) would invalidate the signature and bring back the strict-verify failures we're already accepting only for FinderInfo.

## Implementation Notes
*To be filled during implementation with the actual flash verification result, scripted check output, and any deviations from this spec.*
