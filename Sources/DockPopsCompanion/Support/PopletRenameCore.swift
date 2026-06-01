//  PopletRenameCore.swift
//  ─────────────────────────────────────────────────────────────────────────
//  COPIED VERBATIM from DockPops Complete's handoff artifact
//  (`docs/handoffs/PopletRenameCore.swift` in `…/3. DockPops`) per
//  `docs/handoffs/companion-poplet-rename-and-tcc-fix.md`. It is the *tested*
//  rename/occupant-safety algorithm extracted from the main repo's
//  PopletGenerator.swift — kept byte-for-byte so the same logic drives both
//  channels (re-deriving it from prose is how the subtle bugs creep back).
//  Do not edit the algorithm here; if it changes upstream, re-copy.
//  Wired into the sync loop by PopletSyncService; concrete PopletTerminating
//  is RunningApplicationPopletTerminator.
//
//  ╔══════════════════════════════════════════════════════════════════════╗
//  ║ COPY THIS (verbatim — it's pure / static + dependency-injected):       ║
//  ║   • everything in this file: the PopletRenameCore enum + nested types  ║
//  ║     + the PopletTerminating protocol.                                  ║
//  ║   • Only dependency is Foundation. No App-Group, no PopletPaths, no    ║
//  ║     LauncherGroup, no registry, no os.Logger.                          ║
//  ╠══════════════════════════════════════════════════════════════════════╣
//  ║ ADAPT THIS (wire to YOUR app — do NOT copy from the main repo):        ║
//  ║   • Your sync loop: build [PopletRenamePlan] from your registry's      ║
//  ║     (popID, currentFilename) vs desired "<PopName>.app", then          ║
//  ║       let plan = PopletRenameCore.planRenames(requests)                ║
//  ║       let outcomes = PopletRenameCore.executeRenamePlan(plan, …)        ║
//  ║     and apply each Pop's outcome (see INTEGRATION below).              ║
//  ║   • A concrete PopletTerminating (NSRunningApplication.terminate()).   ║
//  ║   • Your registry filename update (do it BEFORE writing — regen-clobber║
//  ║     lesson in the spec), the Poplets directory URL, the failure banner ║
//  ║     UI, and the trigger/debounce.                                      ║
//  ║   • The MAS-reader / collision-suffix decision (spec §3).              ║
//  ╠══════════════════════════════════════════════════════════════════════╣
//  ║ WATCH OUT:                                                             ║
//  ║   • Type-name collisions — Companion already had a generator, so it    ║
//  ║     may define its own PopletRenamePlan / registry / terminator.       ║
//  ║     Reconcile names; the enum namespace here helps avoid clashes.      ║
//  ║   • The bundle-id scheme below MUST match what your generator stamps.  ║
//  ╚══════════════════════════════════════════════════════════════════════╝
//
//  INTEGRATION (pseudocode for your sync loop):
//
//    var requests: [PopletRenameCore.PopletRenamePlan] = []
//    var originalFrom: [UUID: String] = [:]
//    for pop in pops {
//        let desired = "\(resolvedName(pop)).app"   // collision-free across pops
//        if case .rename(let from) = PopletRenameCore.renameAction(
//               existingFilename: registry[pop.id]?.filename, desiredFilename: desired) {
//            requests.append(.init(popID: pop.id, from: from, to: desired))
//            originalFrom[pop.id] = from
//        }
//    }
//    let outcomes = PopletRenameCore.executeRenamePlan(
//        PopletRenameCore.planRenames(requests),
//        originalFrom: originalFrom, directory: popletsDir,
//        terminator: myTerminator, fileManager: .default)
//    // then per pop:
//    //   .renamed(name)  → registry.filename = name; refresh LaunchServices
//    //   .deferred(name) → keep name; converges next sync (no banner)
//    //   .failed(name)   → keep name (pin valid); show the re-pin banner
//    //   .recreate / nil → write a fresh bundle at the desired name, but FIRST
//    //                     run freshWriteFilename(desired:popID:…) so you don't
//    //                     clobber a foreign occupant.
//    //   For a brand-new pop (no registry entry) use freshWriteFilename too.

import Foundation

/// Terminate the resident `.accessory` Poplet so its `.app` directory isn't
/// "open" when we rename it. Implement with
/// `NSRunningApplication.runningApplications(withBundleIdentifier:)` +
/// `.terminate()` (then `.forceTerminate()` past the timeout). A no-match is a
/// no-op success.
public protocol PopletTerminating {
    func terminateRunningPoplet(bundleID: String, timeout: Duration) -> Bool
}

public enum PopletRenameCore {

    /// Poplet bundle-id scheme — `com.dockpops.poplet.<lowercased-uuid>`. MUST
    /// match what your generator stamps into each bundle (it's shared across
    /// channels so the main app can route Dock clicks).
    public static let popletBundleIDPrefix = "com.dockpops.poplet."

    // MARK: - Value types

    /// A single rename request / step. `from`/`to` are bare `.app` filenames in
    /// the Poplets directory.
    public struct PopletRenamePlan: Equatable {
        public let popID: UUID
        public let from: String
        public let to: String
        public init(popID: UUID, from: String, to: String) {
            self.popID = popID; self.from = from; self.to = to
        }
    }

    /// One ordered step of a rename batch. A cycle member yields TWO steps
    /// (`from`→temp, then temp→`to`) sharing the same `popID`/inode.
    public struct PlannedRename: Equatable {
        public let popID: UUID
        public let from: String
        public let to: String
    }

    /// Outcome of a single `performBundleRename`.
    public enum PopletRenameResult {
        case renamed
        case deferred           // target name occupied by a different bundle
        case noBundle           // source missing — caller creates fresh
        case failed(Error)      // real failure — caller rolls back + flags banner
    }

    /// End state of a Pop's slice of a rename batch (drives filename + banner).
    public enum BatchRenameOutcome: Equatable {
        case renamed(String)
        case deferred(String)
        case failed(String)
        case recreate
    }

    /// Pure reconciliation between the existing filename and the desired name.
    public enum RenameAction: Equatable {
        case create               // no existing bundle — write fresh
        case keep                 // existing == desired
        case rename(from: String) // existing differs — rename in place
    }

    static func renameAction(existingFilename: String?, desiredFilename: String) -> RenameAction {
        guard let existingFilename else { return .create }
        return existingFilename == desiredFilename ? .keep : .rename(from: existingFilename)
    }

    static func isUUIDFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(".app") else { return false }
        return UUID(uuidString: String(filename.dropLast(4))) != nil
    }

    // MARK: - Temp-hop names (cycle breaking)

    static func renameTempFilename(for popID: UUID) -> String {
        ".dockpops-rename-\(popID.uuidString).app.tmp"
    }

    static func isRenameTempFilename(_ filename: String) -> Bool {
        filename.hasPrefix(".dockpops-rename-") && filename.hasSuffix(".app.tmp")
    }

    // MARK: - Batch planner (swap/cycle deadlock)

    /// Orders a batch so EVERY step's destination is free when it runs, breaking
    /// swap/cycle deadlocks by routing one member of each cycle through a temp.
    /// Precondition: `to` names are collision-free across Pops (your suffix
    /// uniquifier guarantees it). Inode preserved on every hop → pins follow.
    static func planRenames(_ requests: [PopletRenamePlan]) -> [PlannedRename] {
        var pending = requests.filter { $0.from != $0.to }
        guard !pending.isEmpty else { return [] }

        var moves: [PlannedRename] = []
        var occupied = Set(pending.map(\.from))
        var currentFrom: [UUID: String] = Dictionary(uniqueKeysWithValues: pending.map { ($0.popID, $0.from) })

        while !pending.isEmpty {
            var progressed = false
            var stillPending: [PopletRenamePlan] = []
            for request in pending {
                let source = currentFrom[request.popID] ?? request.from
                if occupied.contains(request.to) {
                    stillPending.append(request)
                } else {
                    moves.append(PlannedRename(popID: request.popID, from: source, to: request.to))
                    occupied.remove(source)
                    progressed = true
                }
            }
            pending = stillPending
            if !pending.isEmpty && !progressed {
                let victim = pending.removeFirst()
                let source = currentFrom[victim.popID] ?? victim.from
                let temp = renameTempFilename(for: victim.popID)
                moves.append(PlannedRename(popID: victim.popID, from: source, to: temp))
                occupied.remove(source)
                currentFrom[victim.popID] = temp
                pending.append(victim)
            }
        }
        return moves
    }

    // MARK: - Batch executor

    static func executeRenamePlan(
        _ plan: [PlannedRename],
        originalFrom: [UUID: String],
        directory: URL,
        terminator: PopletTerminating,
        fileManager: FileManager
    ) -> [UUID: BatchRenameOutcome] {
        var outcome: [UUID: BatchRenameOutcome] = [:]
        var currentLoc: [UUID: String] = originalFrom

        func rollBackFromTemp(_ popID: UUID, parkedAt loc: String) -> (name: String, ok: Bool) {
            guard isRenameTempFilename(loc), let original = originalFrom[popID] else { return (loc, false) }
            let rolled = performBundleRename(
                plan: PopletRenamePlan(popID: popID, from: loc, to: original),
                directory: directory, terminator: terminator, fileManager: fileManager
            )
            if case .renamed = rolled { currentLoc[popID] = original; return (original, true) }
            return (loc, false)
        }

        for move in plan {
            switch outcome[move.popID] {
            case .failed, .recreate: continue
            default: break
            }

            if isRenameTempFilename(move.to) {
                try? fileManager.removeItem(at: directory.appending(path: move.to, directoryHint: .isDirectory))
            }

            let result = performBundleRename(
                plan: PopletRenamePlan(popID: move.popID, from: move.from, to: move.to),
                directory: directory, terminator: terminator, fileManager: fileManager
            )

            switch result {
            case .renamed:
                currentLoc[move.popID] = move.to
                outcome[move.popID] = isRenameTempFilename(move.to) ? .deferred(move.to) : .renamed(move.to)
            case .noBundle:
                outcome[move.popID] = .recreate
            case .deferred:
                // Classify the blocker by its embedded DockPopsTargetPopID:
                //   • == move.popID → a self-duplicate of THIS Pop at the target
                //     (e.g. a registry rollback). Remove the redundant copy and
                //     finish the rename (your sweep keeps live-Pop ids, so defer
                //     would loop forever).
                //   • nil → FOREIGN `.app`; your sweep PRESERVES it, so defer
                //     loops forever — uniquify past it (freshWriteFilename).
                //   • another id → a sweepable dead orphan; defer and converge
                //     next sync after your sweep clears it.
                let loc = currentLoc[move.popID] ?? move.from
                let occupantURL = directory.appending(path: move.to, directoryHint: .isDirectory)
                let occupantID = embeddedTargetPopID(in: occupantURL, fileManager: fileManager)

                func deferKeepingValidName() {
                    let rolled = rollBackFromTemp(move.popID, parkedAt: loc)
                    outcome[move.popID] = rolled.ok ? .deferred(rolled.name)
                        : (isRenameTempFilename(loc) ? .failed(loc) : .deferred(loc))
                }
                func retryMove(to target: String) {
                    let retried = performBundleRename(
                        plan: PopletRenamePlan(popID: move.popID, from: loc, to: target),
                        directory: directory, terminator: terminator, fileManager: fileManager
                    )
                    if case .renamed = retried {
                        currentLoc[move.popID] = target
                        outcome[move.popID] = .renamed(target)
                    } else { deferKeepingValidName() }
                }

                if occupantID == move.popID.uuidString {
                    try? fileManager.removeItem(at: occupantURL)
                    retryMove(to: move.to)
                } else if occupantID == nil {
                    let free = freshWriteFilename(desired: move.to, popID: move.popID, directory: directory, fileManager: fileManager)
                    if free == loc { deferKeepingValidName() } else { retryMove(to: free) }
                } else {
                    deferKeepingValidName()
                }
            case .failed:
                let loc = currentLoc[move.popID] ?? move.from
                let landing = rollBackFromTemp(move.popID, parkedAt: loc).name
                outcome[move.popID] = .failed(landing)
            }
        }
        return outcome
    }

    // MARK: - Single rename (terminate → inode-preserving move)

    static func performBundleRename(
        plan: PopletRenamePlan,
        directory: URL,
        terminator: PopletTerminating,
        fileManager: FileManager,
        terminateTimeout: Duration = .seconds(2)
    ) -> PopletRenameResult {
        let source = directory.appending(path: plan.from, directoryHint: .isDirectory)
        let destination = directory.appending(path: plan.to, directoryHint: .isDirectory)

        guard fileManager.fileExists(atPath: source.path) else { return .noBundle }

        // Case-only rename (`foo.app`→`Foo.app`) on a case-insensitive volume:
        // the destination "exists" because it's the SAME bundle. Real rename.
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        let caseOnlyRename = destinationExists && isSameFile(source, destination, fileManager: fileManager)

        if destinationExists && !caseOnlyRename {
            return .deferred  // a genuinely different occupant — never clobber
        }

        let bundleID = "\(popletBundleIDPrefix)\(plan.popID.uuidString.lowercased())"
        _ = terminator.terminateRunningPoplet(bundleID: bundleID, timeout: terminateTimeout)

        do {
            if caseOnlyRename {
                // moveItem refuses a "file exists" destination; hop through a temp
                // so each step has a free destination. Roll back on second-hop fail.
                let temp = directory.appending(path: renameTempFilename(for: plan.popID), directoryHint: .isDirectory)
                try? fileManager.removeItem(at: temp)
                try renameBundlePreservingInode(from: source, to: temp, fileManager: fileManager)
                do {
                    try renameBundlePreservingInode(from: temp, to: destination, fileManager: fileManager)
                } catch {
                    try? renameBundlePreservingInode(from: temp, to: source, fileManager: fileManager)
                    return .failed(error)
                }
            } else {
                try renameBundlePreservingInode(from: source, to: destination, fileManager: fileManager)
            }
            return .renamed
        } catch {
            return .failed(error)
        }
    }

    /// Inode-preserving rename via an `NSFileCoordinator` coordinated move
    /// (`.forMoving` / `.forReplacing`). `moveItem` on the same volume is
    /// `rename(2)` (inode preserved, so the Dock pin's bookmark follows); the
    /// coordinator posts the LaunchServices/file-presenter notification Finder
    /// does, which is what makes the relabel + pin survival work. A plain
    /// `moveItem` preserves the inode but SKIPS that notification — don't use it.
    static func renameBundlePreservingInode(from source: URL, to destination: URL, fileManager: FileManager) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            coordinator.item(at: source, willMoveTo: destination)
            do {
                try fileManager.moveItem(at: coordinatedSource, to: coordinatedDestination)
                coordinator.item(at: source, didMoveTo: destination)
            } catch { moveError = error }
        }
        if let moveError { throw moveError }
        if let coordinationError { throw coordinationError }
    }

    // MARK: - Occupant safety

    /// A filename safe to create/recreate at WITHOUT clobbering a foreign
    /// occupant. Returns `desired` if free or held by OUR bundle for `popID`
    /// (adopt a registry-less bundle); else the next free `<base> <n>.app`.
    static func freshWriteFilename(desired: String, popID: UUID, directory: URL, fileManager: FileManager) -> String {
        func isBlocked(_ filename: String) -> Bool {
            let url = directory.appending(path: filename, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: url.path) else { return false }
            return embeddedTargetPopID(in: url, fileManager: fileManager) != popID.uuidString
        }
        guard isBlocked(desired) else { return desired }
        let base = desired.hasSuffix(".app") ? String(desired.dropLast(4)) : desired
        var suffix = 2
        while true {
            let candidate = "\(base) \(suffix).app"
            if !isBlocked(candidate) { return candidate }
            suffix += 1
        }
    }

    /// Same on-disk object (inode + device) — e.g. a case-only difference on a
    /// case-insensitive volume.
    static func isSameFile(_ a: URL, _ b: URL, fileManager: FileManager) -> Bool {
        guard
            let attrsA = try? fileManager.attributesOfItem(atPath: a.path),
            let attrsB = try? fileManager.attributesOfItem(atPath: b.path),
            let inodeA = attrsA[.systemFileNumber] as? Int, let inodeB = attrsB[.systemFileNumber] as? Int,
            let deviceA = attrsA[.systemNumber] as? Int, let deviceB = attrsB[.systemNumber] as? Int
        else { return false }
        return inodeA == inodeB && deviceA == deviceB
    }

    /// Reads `DockPopsTargetPopID` from a bundle's Info.plist. nil when the key
    /// is absent (a bundle that isn't ours) or the plist is unreadable.
    static func embeddedTargetPopID(in bundleURL: URL, fileManager: FileManager) -> String? {
        let infoPlistURL = bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Info.plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path),
              let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let target = plist["DockPopsTargetPopID"] as? String
        else { return nil }
        return target
    }

    // MARK: - Icon bundle version (rebake-skip predicate, P1)

    /// Content-fingerprinted `CFBundleVersion` for a Pop composite icon. Use this
    /// (NOT a whole-second mtime) in your "is the on-disk bundle current?" skip
    /// predicate — the export path rewrites the composite every ~80ms, so a
    /// truncated timestamp collides and leaves a closed tile with stale art.
    static func popCompositeBundleVersion(forPNG data: Data, baseBuildVersion: String, recipeVersion: Int) -> String {
        "\(baseBuildVersion).\(recipeVersion).\(stableIconFingerprint(for: data))"
    }

    static func stableIconFingerprint(for data: Data) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in data {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return max(1, hash & 0x7fff_ffff)
    }

    /// Only a `.failed` rename warrants the recovery banner.
    static func shouldFlagRecoveryBanner(for result: PopletRenameResult) -> Bool {
        if case .failed = result { return true }
        return false
    }
}
