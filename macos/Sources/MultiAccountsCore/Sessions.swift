import Foundation

/// An account's Code and Cowork session lists follow it into its own window.
///
/// Claude keeps them per account inside its data folder, at `<tree>/<account uuid>/` for each of
/// the trees below, and skips folders reached through a symbolic link. So while an account's window
/// runs, its session folders are moved (renamed, on the same disk) from the main Claude's data
/// folder into the account's folder, and moved back once the window has closed. The main Claude is
/// signed in to another account meanwhile and doesn't read them.
///
/// A marker file in the account's folder says its session folders came from the main Claude. Where
/// both places hold the same file, the copy with the account's history wins; an identical other copy
/// is deleted and a different one is kept under `session-conflicts/` in the account's folder.
extension AccountManager {
    static let sessionTrees = ["claude-code-sessions", "local-agent-mode-sessions"]
    static let sessionsMarker = ".swap-sessions-here"

    /// Moves an account's session folders from the main Claude into its own folder, before its
    /// window opens. Expects the lock, and neither Claude to be using them.
    func takeSessions(of account: Account) throws {
        let folder = layout.folder(of: account)
        for tree in Self.sessionTrees {
            let main = layout.liveData.appendingPathComponent(tree).appendingPathComponent(account.uuid)
            let own = folder.appendingPathComponent(tree).appendingPathComponent(account.uuid)
            guard Self.isFolder(main) else { continue }
            if Self.isFolder(own) {
                // Left by a window opened before session lists moved with it.
                try Self.absorb(own, into: main, conflicts: conflictsFolder(folder, tree, account.uuid))
            }
            try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.move(main, to: own)
        }
        try Data().write(to: folder.appendingPathComponent(Self.sessionsMarker))
        log("Moved the session list of “\(account.name)” into its window's folder")
    }

    /// Moves an account's session folders back to the main Claude once its window has closed.
    /// Expects the lock.
    func returnSessions(of account: Account) throws {
        let folder = layout.folder(of: account)
        let marker = folder.appendingPathComponent(Self.sessionsMarker)
        let ownIsHistory = Files.exists(marker)
        var moved = false
        for tree in Self.sessionTrees {
            let main = layout.liveData.appendingPathComponent(tree).appendingPathComponent(account.uuid)
            let own = folder.appendingPathComponent(tree).appendingPathComponent(account.uuid)
            guard Self.isFolder(own) else { continue }
            if !Self.isFolder(main) {
                try FileManager.default.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.move(own, to: main)
            } else if ownIsHistory {
                try Self.absorb(main, into: own, conflicts: conflictsFolder(folder, tree, account.uuid))
                try Self.move(own, to: main)
            } else {
                try Self.absorb(own, into: main, conflicts: conflictsFolder(folder, tree, account.uuid))
            }
            moved = true
        }
        try? FileManager.default.removeItem(at: marker)
        if moved { log("Moved the session list of “\(account.name)” back to the main Claude") }
    }

    /// Returns the session folders of every account whose window has closed, unless the main
    /// Claude is running signed in to that account (its own copy is then in use). Expects the lock.
    func returnSessionsFromClosedWindows() {
        guard let main = try? mainState() else { return }
        for account in accounts() {
            let folder = layout.folder(of: account)
            guard Self.sessionTrees.contains(where: { Self.isFolder(folder.appendingPathComponent($0).appendingPathComponent(account.uuid)) }),
                  claude.pid(usingDataFolder: folder) == nil,
                  !(main.running && main.signedIn && main.uuid == account.uuid) else { continue }
            do {
                try returnSessions(of: account)
            } catch {
                log("Couldn't move the session list of “\(account.name)” back: \(error.localizedDescription)")
            }
        }
    }

    private func conflictsFolder(_ folder: URL, _ tree: String, _ uuid: String) -> URL {
        folder.appendingPathComponent("session-conflicts/\(Self.folderStamp.string(from: Date()))/\(tree)/\(uuid)", isDirectory: true)
    }

    /// Moves everything in `stray` that `history` lacks into it, then removes `stray`. Where both
    /// have a file, `history`'s stays: an identical stray copy is deleted, a different one goes to
    /// `conflicts`.
    static func absorb(_ stray: URL, into history: URL, conflicts: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: stray.path) {
            let from = stray.appendingPathComponent(name)
            let to = history.appendingPathComponent(name)
            if !exists(to) {
                try move(from, to: to)
            } else if isFolder(from) && isFolder(to) {
                try absorb(from, into: to, conflicts: conflicts.appendingPathComponent(name))
            } else if !isFolder(from) && !isFolder(to) && fm.contentsEqual(atPath: from.path, andPath: to.path) {
                try fm.removeItem(at: from)
            } else {
                try fm.createDirectory(at: conflicts, withIntermediateDirectories: true)
                try move(from, to: conflicts.appendingPathComponent(name))
            }
        }
        guard rmdir(stray.path) == 0 else {
            throw SwapError.io("Couldn't remove \(stray.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Renames, refusing to replace anything or to copy across disks, so a move can't half happen.
    static func move(_ from: URL, to: URL) throws {
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            throw SwapError.io("Couldn't move \(from.path) to \(to.path): \(String(cString: strerror(errno)))")
        }
    }

    /// A real folder, not a symbolic link to one.
    static func isFolder(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
