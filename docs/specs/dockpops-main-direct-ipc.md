# DockPops Main — Direct DistributedNotification IPC for Poplet Opens

**Audience:** the DockPops Main coder (works in `../3. DockPops/`).
**Companion side:** already shipped on the Companion's `main` branch
(commit `[fill in after committing]` — replaces the Companion-mediated
approach in `darwin-notification-companion.md`).
**Target:** DockPops Main 4.1+.

This document is self-contained. You don't need to read the prior
`darwin-notification-companion.md` spec to implement this — read this
one. The change supersedes the App-Group + Darwin-notification dance:
the same Poplet click event is now delivered as a single
`DistributedNotificationCenter` post that carries the payload natively
in `userInfo`.

---

## 1. Context (one paragraph)

DockPops 4.0 (and the `feat/darwin-ipc` 4.1 listener pair from the prior
spec) had Poplets fire a `dockpops://` URL on every click. In Menu Bar
mode (`NSApp.setActivationPolicy(.accessory)`) that URL delivery causes
a visible Dock-tile flash (LaunchServices' GURL Apple Event transiently
asserts regular activation on the receiver). The original fix added a
Darwin-notification + App-Group payload IPC channel that bypassed
LaunchServices. That works — *except* per-pop Poplet `.app` bundles are
**ad-hoc signed** (the Companion generates them at runtime; no Developer
ID key is available on user machines), and macOS 26 TCC will not anchor
consent for an App-Group entitlement to an ad-hoc identity. Result: the
ad-hoc Poplet was correctly redirected by cfprefsd (so the IPC worked
*and* the flash was gone), but TCC re-prompted "...would like to access
data from other apps" on every click. The fix is to drop the App-Group
hop entirely and deliver the payload directly via
`DistributedNotificationCenter`, which (a) carries `userInfo`, (b) needs
no entitlement, and (c) does not flow through LaunchServices. The
Companion side already does this.

---

## 2. The contract DockPops 4.1+ must implement

### 2.1 Observer

Register a `DistributedNotificationCenter` observer at app launch:

```swift
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.dockpops.poplet.openRequest"),
    object: nil,
    queue: .main
) { notification in
    // …handler, see § 2.4…
}
```

It is fine for this to live next to (or replace) the existing Darwin
notification listener — they use independent transports, the name string
just happens to be the same.

### 2.2 Notification name

**`com.dockpops.poplet.openRequest`**

Same string as the Darwin notification name from the prior spec
(Sacred Zone #20). Reusing it intentionally — the Companion is no longer
posting on the Darwin center for this event, so there is no collision.

### 2.3 `userInfo` schema

Exactly the same shape as the prior `pendingPopletOpen` App-Group
payload, just carried in the notification itself:

| Key | Type | Meaning |
|---|---|---|
| `pop` | `String` | Pop UUID (validate with `UUID(uuidString:)`; reject otherwise). |
| `x` | `Double` | Mouse X at click time, in screen coordinates. |
| `y` | `Double` | Mouse Y at click time, in screen coordinates. |
| `locked` | `Bool` | `true` for Poplet opens (matches the legacy `locked=1` URL parameter). |
| `source` | `String` | `"poplet"` for the Companion path. |
| `timestamp` | `Double` | `Date().timeIntervalSince1970` at write time. Use it to drop stale repeats if you want; otherwise ignore. |

If any required field is missing or malformed, bail (don't open the
popover). Treat the notification as untrusted input from another
process — validate before acting.

### 2.4 What the handler does

The same thing the existing Darwin handler does when it reads
`pendingPopletOpen`: open the popover for the named Pop anchored at
`(x, y)`, treating `source == "poplet"` as the Companion path (so the
popover anchors at the supplied coordinates even when DockPops is in
Menu Bar mode — without this DockPops would anchor at the menu bar).

Pseudo-code:

```swift
{ notification in
    guard let info = notification.userInfo else { return }
    guard
        let popID = (info["pop"] as? String).flatMap(UUID.init(uuidString:)),
        let x = info["x"] as? Double,
        let y = info["y"] as? Double
    else { return }
    let locked = (info["locked"] as? Bool) ?? true
    let source = (info["source"] as? String) ?? "poplet"

    Task { @MainActor in
        openPopover(
            popID: popID,
            anchor: CGPoint(x: x, y: y),
            locked: locked,
            source: source
        )
    }
}
```

### 2.5 Order of operations

The DistributedNotification carries the payload directly, so the
prior `write App Group → then post Darwin` ordering rule is gone. There
is one post; everything is in it.

### 2.6 What does NOT change

- Cold-start path: a click while DockPops is not running still arrives
  through the legacy `dockpops://open?...` URL. Keep the existing URL
  handler intact. The Companion side checks `runningApplications` for
  `com.dockpops.app` and chooses URL vs DistributedNotification
  accordingly. A one-time Dock flash on cold launch is accepted UX.
- Drop forwarding: file drops onto a Poplet still go through the URL
  scheme (Sacred Zone #20 § 8 — out of scope for IPC migration).
- All other DockPops Apple-Event / shortcut entry points.

---

## 2.7 Live icon push — `com.dockpops.poplet.iconUpdated`

Today the Companion is the only thing that pushes pop icon changes out
to Poplets — it watches the App-Group `PopIcons` directory and mirrors
to a Library/Application Support cache that the Poplet's
`PopletLiveIconController` reads. That means: **if the Companion isn't
running, the Poplet's live tile shows whatever the mirror had last
time.** DockPops can fix this with one more notification.

### 2.7.1 What DockPops Main should post

Whenever DockPops changes a pop's icon (user edits color, dynamic icon
recipe ticks, anything that writes `PopIcons/<uuid>.png`), post:

```swift
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.dockpops.poplet.iconUpdated"),
    object: nil,
    userInfo: [
        "pop": "<UUID string>",
        "iconData": <PNG bytes as Data>,
    ],
    deliverImmediately: true
)
```

Recommended image: a **256×256 PNG** (typically 10–30 KB). Plenty of
resolution for the Dock tile, well under any `distnoted` userInfo size
ceiling. Don't send a full 1024×1024 — it bloats the broadcast and
DistributedNotifications get unreliable past ~50 KB userInfo.

### 2.7.2 Piggyback on `openRequest`

Cold-launched Poplets miss any broadcasts that fired while they weren't
running. When DockPops handles an incoming `openRequest`, immediately
post the matching `iconUpdated` for that pop's current icon, *then*
open the popover. The fresh-from-IPC icon arrives ~milliseconds after
the Poplet's `PopletLiveIconController` registers its observer, which
means every click → fresh icon, no Companion required.

Order suggestion:

```swift
{ notification in
    // …validate userInfo as in § 2.4…
    Task { @MainActor in
        broadcastIconUpdate(forPop: popID)   // post iconUpdated first
        openPopover(popID: popID, …)         // then open the popover
    }
}
```

Posting the icon first means it lands in the Poplet's observer queue
before the popover animation starts — visually the tile and the popover
update together.

### 2.7.3 What the Poplet does with it

`PopletLiveIconController` (Companion repo) observes this exact
notification, filters by its own `popID`, decodes the PNG, runs it
through the normalized presentation canvas (0.832 inset + rounded
mask), and sets `NSApp.applicationIconImage`. Already implemented on
the Companion side.

### 2.7.4 Acceptance criteria for the icon push

- [ ] With DockPops 4.1+ running and a Poplet running: change a pop's
      icon in DockPops → the Poplet's Dock tile updates within ~100 ms
      with **no Companion running**.
- [ ] Cold-launch path: click a Poplet that wasn't running → the
      Poplet's live tile shows the current icon as the popover opens,
      not a stale one.
- [ ] No regression to the existing Companion-mirror path: with the
      Companion running, both mechanisms fire and the last one wins;
      they converge on the same icon.

---

## 3. What to do with the old Darwin listener

Two options; either is fine.

**Option A — delete it.** The Companion no longer posts on the Darwin
center for this event. The `pendingPopletOpen` App-Group key is no
longer written by anyone. Removing the listener is a net reduction in
surface area.

**Option B — keep it as a back-compat fallback.** If you still have
deployed Companion 4.0 builds in the wild that post on the Darwin
center, leave the listener registered so they still work. Note that the
Companion side ships in lockstep with this DockPops change, so there
is no deployed Companion that uses the Darwin transport — Option A is
fine for first-party.

---

## 4. Acceptance criteria

- [ ] DockPops 4.1+ registers a `DistributedNotificationCenter` observer
      on `com.dockpops.poplet.openRequest` at app launch.
- [ ] With DockPops 4.1+ in Menu Bar mode (`.accessory`) and the
      Companion's current 4.1 Poplet binary deployed: clicking a Poplet
      opens the popover at the supplied coordinates **with no Dock-tile
      flash** and **no TCC prompt**.
- [ ] Invalid payloads (missing `pop`, malformed UUID, missing
      coordinates) are silently dropped — DockPops does not crash and
      does not open a wrong popover.
- [ ] Cold-start path (Companion's URL fallback) is unaffected — a
      `dockpops://open?...` URL still opens the popover at the supplied
      coordinates.

---

## 5. Verification

- **Manual smoke:** with DockPops running in Menu Bar mode, click a
  freshly-built Poplet → popover appears at the cursor, no Dock flash,
  no TCC prompt.
- **Console / OSLog (DockPops side):** log a line on every observer fire
  so you can confirm the path is hit. Hot-path clicks should log; cold-
  path (DockPops not running before click) should fall through to the
  URL handler.
- **Cross-version smoke:** Companion 4.1 + DockPops 4.0 (old DockPops
  with no observer) → Companion sees DockPops running, posts the
  DistributedNotification, DockPops 4.0 ignores it, user's click does
  nothing. Mixed-version state we accept transiently — ship DockPops 4.1
  and Companion 4.1 together, or DockPops 4.1 first.

---

## 6. Sacred-zone notes

The DockPops repo's `.claude/rules/sacred-carousel.md` Sacred Zone #20
documents canonical names for this IPC. This spec re-uses the
notification name (`com.dockpops.poplet.openRequest`) on a different
transport (DistributedNotificationCenter instead of Darwin); the
App-Group key (`pendingPopletOpen`) and the
`group.com.dockpops.shared` suite are NO LONGER USED by this IPC path
and should be retired (or kept only if some non-Poplet DockPops feature
still depends on them — independent of this work).

Cite Sacred Zone #20 in your commit; cite this spec; cite the Companion
commit hash that landed the matching change.

---

## 7. Out of scope

- **Poplet file drops** — stay on URL scheme.
- **Companion-side changes** — already done. Don't modify the Companion
  from the DockPops repo.
- **Any change to the URL-scheme handler** — keep it. The cold-start
  fallback depends on it.

---

## 8. Companion-side reference (for code review)

The matching Companion-side code lives in:

- `../3.5 DockPops Companion/Sources/DockPopsPoplet/DockPopsPopletMain.swift`
  — `postOpenPopToDockPops(mouse:)` and the `PopletDockPopsIPC` enum.
  Source of `openRequest` posts.
- `../3.5 DockPops Companion/Sources/DockPopsPoplet/PopletLiveIconController.swift`
  — `installIconUpdateObserver()` and `applyIconFromIPC(_:)`. Consumer of
  `iconUpdated` posts. `Self.iconUpdateNotificationName` is the canonical
  string the observer registers for.

Read those pieces to verify both notification names, both userInfo
schemas, and the running-app gate match what this listener expects.
