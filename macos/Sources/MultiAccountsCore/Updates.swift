import Foundation

/// Claude windows closed by Claude's own updates come back.
///
/// Once an update has downloaded, a Claude window that sits unfocused and idle for 10 minutes quits
/// to install it, leaving the note `stealth-relaunch` in its data folder. Claude reads that note, and
/// deletes it, when it starts again. Its updater (Squirrel's ShipIt) waits until every copy of
/// Claude has quit, installs the update and then opens the main Claude only: it knows nothing of
/// the other copies' data folders. So an account's window that quit this way never came back, and
/// a main Claude that quit this way stayed away while any account's window was open.
extension AccountManager {
    static let updateQuitNote = "stealth-relaunch"
    /// Claude ignores an older note when it starts, and so does this.
    static let updateQuitNoteLifetime: TimeInterval = 300

    /// Opens again the main Claude and every account's window that quit to install an update in the
    /// last five minutes, behind the app in front, once per quit. While the updater is installing
    /// (it runs and every copy of Claude has quit), it waits for the updater to finish and open the
    /// main Claude, so nothing starts from a Claude.app being replaced. Skipped while something else
    /// is changing accounts; the next call tries again.
    public func reopenWindowsClosedByUpdates(now: Date = Date()) {
        // Most of the time there is no note, so look for one before looking through the processes.
        let folders = [layout.liveData] + accounts().map(layout.folder(of:))
        guard folders.contains(where: { unhandledUpdateQuit(in: $0, now: now) != nil }),
              claude.anyInstanceRunning() || !claude.updaterRunning() else { return }
        _ = try? withLock {
            if claude.mainPID() == nil, let note = unhandledUpdateQuit(in: layout.liveData, now: now) {
                handledUpdateQuits.insert(note)
                log("Claude quit to install an update; opening it again")
                do {
                    try claude.launchMain(app: layout.claudeApp, inBackground: true)
                } catch {
                    log("Couldn't open Claude again: \(error.localizedDescription)")
                }
            }
            let main = try? mainState()
            for account in accounts() where !(main?.signedIn == true && main?.uuid == account.uuid) {
                let folder = layout.folder(of: account)
                guard claude.pid(usingDataFolder: folder) == nil,
                      let note = unhandledUpdateQuit(in: folder, now: now) else { continue }
                handledUpdateQuits.insert(note)
                log("Claude closed the window of “\(account.name)” to install an update; opening it again")
                do {
                    try openWindowHoldingLock(account.uuid, inBackground: true)
                } catch {
                    log("Couldn't open the window of “\(account.name)” again: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The note in `dataFolder` saying Claude quit there to install an update, as a key to remember
    /// it by, when Claude wrote it in the last five minutes and it hasn't been acted on yet. Quitting
    /// by hand, or Claude restarting itself (it then reopens on its own), marks the note `userQuit`
    /// or `navOnly`, and those are left alone.
    func unhandledUpdateQuit(in dataFolder: URL, now: Date) -> String? {
        guard let note = try? Login.readJSON(dataFolder.appendingPathComponent(Self.updateQuitNote)),
              let written = note["ts"] as? Double,
              note["userQuit"] as? Bool != true, note["navOnly"] as? Bool != true else { return nil }
        let key = "\(dataFolder.path) \(written)"
        let age = now.timeIntervalSince1970 - written / 1000
        guard (0..<Self.updateQuitNoteLifetime).contains(age), !handledUpdateQuits.contains(key) else { return nil }
        return key
    }
}
