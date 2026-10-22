import Foundation

/// Where an account's sign-in is now.
public enum Place: String, Equatable, Sendable {
    /// Signed in to the main Claude.
    case main
    /// Open in its own Claude window, next to the main one.
    case window
    /// Kept in its folder, ready to switch to or to open in its own window.
    case saved
    /// Known, but its sign-in is saved only when the main Claude switches away from it.
    case notSaved
}

public struct AccountStatus: Equatable, Identifiable, Sendable {
    public var account: Account
    /// Its place in the list, starting at 1; the command line accepts it instead of the name.
    public var number: Int
    public var place: Place
    /// The account's own Claude window, if one runs. For the main account this means it is
    /// signed in twice, which blocks switching until that window closes.
    public var windowPID: pid_t?
    /// When its claude.ai sign-in expires: nil when expired or signed out, `.distantFuture` when
    /// it lasts until Claude quits.
    public var loginExpires: Date?
    /// Whether its folder holds a saved sign-in (the main account keeps the copy from its last switch).
    public var hasSavedSignIn: Bool
    public var folder: URL

    public var id: String { account.uuid }
    public var isSignedInTwice: Bool { place == .main && windowPID != nil }
}

/// The main Claude: whether it runs and what it is signed in to.
public struct MainState: Equatable, Sendable {
    public var pid: pid_t?
    public var signedIn: Bool
    /// The account Claude recorded, when signed in.
    public var uuid: String?
    public var loginExpires: Date?

    public var running: Bool { pid != nil }
}

/// A Claude window opened to sign in to an account that isn't in the list yet.
public struct NewWindow: Equatable, Identifiable, Sendable {
    public var folder: URL
    public var name: String?
    public var pid: pid_t?
    public var id: String { folder.path }
}

public struct Snapshot: Equatable, Sendable {
    public var main: MainState
    public var accounts: [AccountStatus]
    public var newWindows: [NewWindow]

    public var mainAccount: AccountStatus? { accounts.first { $0.place == .main } }
    /// Signed in to an account this tool hasn't named yet.
    public var mainIsUnnamed: Bool { main.signedIn && main.uuid != nil && mainAccount == nil }
}

/// Saves, switches and opens Claude accounts.
///
/// Rules that keep every sign-in working:
/// - Each sign-in lives in exactly one place: the main Claude, its account's folder, or the
///   Claude window running on that folder. Copies are only ever made of a sign-in nothing runs on.
/// - Nothing is changed while the Claude that uses it runs, and nothing is ever force-quit.
/// - The live sign-in is backed up before each change, and nothing is sent to Anthropic. Claude's
///   own "Log out" ends the sign-in on the server, which is exactly what this avoids.
public final class AccountManager {
    public let layout: Layout
    public var quitTimeout: TimeInterval = 90
    /// Time for Claude's helper processes to finish writing after it quits.
    public var settleDelay: TimeInterval = 1.5
    /// How long a new window may take to show up as a running process.
    public var launchTimeout: TimeInterval = 20
    /// How removed account folders leave; tests and the demo keep them out of the real Trash.
    public var moveToTrash: (URL) throws -> Void
    /// The space a folder takes; the demo replaces it to show realistic sizes.
    public var sizeProvider: (URL) -> Int64? = Disk.allocatedSize(of:)
    /// Where the account manager reports what it did, a line at a time.
    public var log: (String) -> Void

    let claude: ClaudeControl
    /// The update notes acted on already (see Updates.swift), so each quit is reopened only once.
    var handledUpdateQuits: Set<String> = []
    static let keepBackups = 20
    static let newWindowMarker = ".swap-new-window.json"

    public init(layout: Layout = .system(), claude: ClaudeControl = SystemClaudeControl()) {
        self.layout = layout
        self.claude = claude
        moveToTrash = { url in
            if let trash = layout.trash {
                try Files.privateFolder(trash)
                try FileManager.default.moveItem(
                    at: url, to: trash.appendingPathComponent("\(url.lastPathComponent)-\(UUID().uuidString.prefix(8))"))
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        log = { message in Self.appendLog(message, to: layout.logFile) }
    }

    // MARK: - Reading

    public func accounts() -> [Account] {
        (try? Registry.load(layout.accountsFile)) ?? []
    }

    public func mainState() throws -> MainState {
        let config = layout.liveData.appendingPathComponent("config.json")
        guard Files.exists(config) else { throw SwapError.noClaudeData(config.path) }
        let expiry = Login.expiry(in: layout.liveData)
        return MainState(pid: claude.mainPID(), signedIn: expiry != nil,
                         uuid: expiry != nil ? Login.accountUUID(in: layout.liveData) : nil,
                         loginExpires: expiry)
    }

    /// Everything at once: the main Claude, every account and any windows still signing in.
    public func snapshot() throws -> Snapshot {
        _ = try? withLock {
            moveOldHome()
            adoptNewWindows()
            returnSessionsFromClosedWindows()
        }
        let main = try mainState()
        let statuses = accounts().enumerated().map { status(of: $0.element, number: $0.offset + 1, main: main) }
        return Snapshot(main: main, accounts: statuses, newWindows: newWindows())
    }

    public func find(_ query: String) throws -> Account {
        try accounts().find(query)
    }

    /// The space an account's folder takes on disk, its own window's data included.
    public func folderSize(of status: AccountStatus) -> Int64? {
        Files.exists(status.folder) ? sizeProvider(status.folder) : nil
    }

    func status(of account: Account, number: Int, main: MainState) -> AccountStatus {
        let folder = layout.folder(of: account)
        let saved = Login.hasSignIn(in: folder)
        let window = claude.pid(usingDataFolder: folder)
        let place: Place
        let expiry: Date?
        if main.signedIn && main.uuid == account.uuid {
            (place, expiry) = (.main, main.loginExpires)
        } else {
            place = window != nil ? .window : saved ? .saved : .notSaved
            expiry = saved ? Login.expiry(in: folder) : nil
        }
        return AccountStatus(account: account, number: number, place: place, windowPID: window,
                             loginExpires: expiry, hasSavedSignIn: saved, folder: folder)
    }

    func newWindows() -> [NewWindow] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: layout.accountsRoot, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { Files.exists($0.appendingPathComponent(Self.newWindowMarker)) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { folder in
                let marker = try? Login.readJSON(folder.appendingPathComponent(Self.newWindowMarker))
                return NewWindow(folder: folder, name: marker?["name"] as? String,
                                 pid: claude.pid(usingDataFolder: folder))
            }
    }

    // MARK: - Switching the main Claude

    /// Puts an account's sign-in in the main Claude: quits Claude, saves the sign-in it had under
    /// its account, puts the target's in its place and opens Claude again. `query` nil picks the
    /// next saved account. With `closeWindow`, a target open in its own window is closed first.
    @discardableResult
    public func switchTo(_ query: String?, nameForCurrent: String? = nil, closeWindow: Bool = false,
                         progress: (String) -> Void = { _ in }) throws -> String {
        try withLock {
            adoptNewWindows()
            var accounts = self.accounts()
            let main = try mainState()
            let target = try query.map { try accounts.find($0) } ?? nextAccount(accounts, main: main)
            if main.signedIn && main.uuid == target.uuid {
                try openMain()
                return "Already signed in as “\(target.name)”."
            }
            let source = layout.folder(of: target)
            guard Login.hasSignIn(in: source) else { throw SwapError.notSavedYet(target.name) }
            try refuseIfSignedInTwice(accounts, main: main)
            try requireClaude()

            if let pid = claude.pid(usingDataFolder: source) {
                guard closeWindow else { throw SwapError.openInWindow(target.name) }
                progress("Closing the window of “\(target.name)”…")
                log("Closing the window of “\(target.name)”")
                try claude.quit(pid: pid, timeout: quitTimeout)
                settle()
            }
            try reopeningOnFailure {
                try quitMain(progress)
                backUpLive("before-switch")
                try saveLive(&accounts, nameForCurrent: nameForCurrent)
            }
            progress("Signing Claude in to “\(target.name)”…")
            try ensureMainQuit()
            try returnSessions(of: target)
            try Login.copy(from: source, to: layout.liveData)
            try launchMain()
            log("Switched to “\(target.name)”")
            return "Switched Claude to “\(target.name)”."
        }
    }

    /// Saves the main Claude's account and reopens Claude signed out, to sign in to another account.
    @discardableResult
    public func addInMain(nameForCurrent: String? = nil, progress: (String) -> Void = { _ in }) throws -> String {
        try withLock {
            adoptNewWindows()
            var accounts = self.accounts()
            try refuseIfSignedInTwice(accounts, main: try mainState())
            try requireClaude()
            var saved: Account?
            try reopeningOnFailure {
                try quitMain(progress)
                backUpLive("before-add")
                saved = try saveLive(&accounts, nameForCurrent: nameForCurrent)
            }
            try ensureMainQuit()
            try Login.copy(from: nil, to: layout.liveData)
            try launchMain()
            let kept = saved.map { "“\($0.name)” is saved. " } ?? ""
            return "\(kept)Claude reopened signed out: sign in with your other account. "
                + "It's saved automatically the next time you switch."
        }
    }

    /// Opens the main Claude, or brings it to the front.
    public func openMain() throws {
        if let pid = claude.mainPID() {
            claude.activate(pid: pid)
        } else {
            try requireClaude()
            try launchMain()
        }
    }

    // MARK: - Side by side

    /// Opens a saved account in its own Claude window, next to the main Claude. The window runs on
    /// the account's folder, so its sign-in stays in one place.
    @discardableResult
    public func openWindow(_ query: String) throws -> String {
        try withLock { try openWindowHoldingLock(query, inBackground: false) }
    }

    /// `openWindow` for a caller that holds the lock; `inBackground` leaves the app in front where it is.
    @discardableResult
    func openWindowHoldingLock(_ query: String, inBackground: Bool) throws -> String {
        adoptNewWindows()
        let account = try find(query)
        let main = try mainState()
        if main.signedIn && main.uuid == account.uuid {
            try openMain()
            return "“\(account.name)” is the account in the main Claude."
        }
        let folder = layout.folder(of: account)
        if let pid = claude.pid(usingDataFolder: folder) {
            claude.activate(pid: pid)
            return "Brought the window of “\(account.name)” to the front."
        }
        guard Login.hasSignIn(in: folder) else { throw SwapError.notSavedYet(account.name) }
        try requireClaude()
        try Login.prepareForWindow(folder, mainData: layout.liveData)
        try takeSessions(of: account)
        do {
            try claude.launchSide(app: layout.claudeApp, dataFolder: folder, inBackground: inBackground)
        } catch {
            try? returnSessions(of: account)
            throw error
        }
        // Keep the lock until the window's process shows, or a refresh in between would take
        // it for closed and move its sessions back.
        let deadline = Date().addingTimeInterval(launchTimeout)
        while claude.pid(usingDataFolder: folder) == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        log("Opened “\(account.name)” in its own window")
        return "Opened “\(account.name)” in its own Claude window."
    }

    /// Quits an account's own Claude window, like ⌘Q in that window. Its sign-in stays in its folder.
    @discardableResult
    public func closeWindow(_ query: String) throws -> String {
        let account = try find(query)
        guard let pid = claude.pid(usingDataFolder: layout.folder(of: account)) else {
            return "“\(account.name)” has no window open."
        }
        try claude.quit(pid: pid, timeout: quitTimeout)
        log("Closed the window of “\(account.name)”")
        settle()
        _ = try? withLock { returnSessionsFromClosedWindows() }
        return "Closed the window of “\(account.name)”."
    }

    /// Opens a Claude window on a new, empty folder, to sign in to another account while the main
    /// Claude keeps running. The account joins the list, named `name`, once it has signed in.
    @discardableResult
    public func addInWindow(name: String?) throws -> URL {
        try withLock {
            let clean = try name.map { try validName($0, among: accounts(), ignoring: nil) }
            try requireClaude()
            let stamp = Self.folderStamp.string(from: Date())
            var folder = layout.accountsRoot.appendingPathComponent("new-\(stamp)", isDirectory: true)
            var n = 2
            while Files.exists(folder) {
                folder = layout.accountsRoot.appendingPathComponent("new-\(stamp)-\(n)", isDirectory: true)
                n += 1
            }
            try Login.prepareForWindow(folder, mainData: layout.liveData)
            try Login.writeJSON(clean.map { ["name": $0] } ?? [:], to: folder.appendingPathComponent(Self.newWindowMarker))
            try claude.launchSide(app: layout.claudeApp, dataFolder: folder)
            log("Opened a new window to sign in to \(clean.map { "“\($0)”" } ?? "another account")")
            return folder
        }
    }

    /// Brings a window that is signing in to a new account forward, or opens it again.
    public func openNewWindow(_ window: NewWindow) throws {
        if let pid = claude.pid(usingDataFolder: window.folder) {
            claude.activate(pid: pid)
        } else {
            try requireClaude()
            try claude.launchSide(app: layout.claudeApp, dataFolder: window.folder)
        }
    }

    /// Quits a window that is signing in to a new account.
    public func closeNewWindow(_ window: NewWindow) throws {
        if let pid = claude.pid(usingDataFolder: window.folder) {
            try claude.quit(pid: pid, timeout: quitTimeout)
        }
    }

    /// Moves the folder of a window that never finished signing in to the Trash.
    public func discardNewWindow(_ window: NewWindow) throws {
        try withLock {
            guard Files.exists(window.folder.appendingPathComponent(Self.newWindowMarker)) else { return }
            if claude.pid(usingDataFolder: window.folder) != nil {
                throw SwapError.io("That window is still open. Close it first.")
            }
            try moveToTrash(window.folder)
            log("Discarded the new-account folder \(window.folder.lastPathComponent)")
        }
    }

    public func activate(pid: pid_t) {
        claude.activate(pid: pid)
    }

    // MARK: - The list

    /// Renames an account. `current` names the account in the main Claude, adding it to the list.
    public func rename(_ query: String, to name: String) throws {
        try withLock {
            var accounts = self.accounts()
            let index: Int
            if query == "current" {
                let main = try mainState()
                guard main.signedIn, let uuid = main.uuid else { throw SwapError.notSignedIn }
                if let existing = accounts.firstIndex(where: { $0.uuid == uuid }) {
                    index = existing
                } else {
                    accounts.append(Account(uuid: uuid, name: try validName(name, among: accounts, ignoring: nil)))
                    index = accounts.count - 1
                }
            } else {
                let account = try accounts.find(query)
                index = accounts.firstIndex { $0.uuid == account.uuid }!
            }
            accounts[index].name = try validName(name, among: accounts, ignoring: accounts[index].uuid)
            try saveAccounts(accounts)
        }
    }

    /// Forgets an account: its folder, with its saved sign-in and its own window's data, goes to
    /// the Trash. The account itself is untouched.
    @discardableResult
    public func remove(_ query: String) throws -> String {
        try withLock {
            let accounts = self.accounts()
            let account = try accounts.find(query)
            let main = try mainState()
            if main.signedIn && main.uuid == account.uuid { throw SwapError.isMain(account.name) }
            let folder = layout.folder(of: account)
            if claude.pid(usingDataFolder: folder) != nil { throw SwapError.openInWindow(account.name) }
            try returnSessions(of: account)
            if Files.exists(folder) { try moveToTrash(folder) }
            try saveAccounts(accounts.filter { $0.uuid != account.uuid })
            log("Removed “\(account.name)”")
            return "Removed “\(account.name)”. The account itself is untouched; "
                + "sign in to it again to add it back."
        }
    }

    /// Checks that this Mac's Claude looks the way this tool expects.
    public func doctor() -> [(name: String, value: String, ok: Bool)] {
        var checks: [(String, String, Bool)] = []
        let version = Bundle(url: layout.claudeApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        checks.append(("Claude app", "\(layout.claudeApp.path)\(version.map { " (\($0))" } ?? "")", Files.exists(layout.claudeApp)))
        checks.append(("Claude data folder", layout.liveData.path, Files.exists(layout.liveData)))
        let keys = Login.keys(in: layout.liveData).map { Array($0.keys).sorted() } ?? []
        checks.append(("config.json sign-in keys", keys.isEmpty ? "none" : keys.joined(separator: ", "), !keys.isEmpty))
        let expiry = Login.expiry(in: layout.liveData)
        checks.append(("claude.ai sign-in cookie", "valid \(Self.describe(expiry))", expiry != nil))
        checks.append(("Main Claude running", claude.mainPID() != nil ? "yes" : "no", true))
        checks.append(("Claude update waiting to install", claude.updaterRunning() ? "yes" : "no", true))
        let open = accounts().filter { claude.pid(usingDataFolder: layout.folder(of: $0)) != nil }.count
        checks.append(("Windows open side by side", String(open), true))
        checks.append(("Saved accounts", String(accounts().count), true))
        checks.append(("Accounts folder", layout.home.path
            + (layout.newHome.map { " (moves to \($0.path) once no window runs on it)" } ?? ""), true))
        return checks
    }

    public static func describe(_ expiry: Date?) -> String {
        guard let expiry else { return "signed out / expired" }
        if expiry == .distantFuture { return "until Claude quits" }
        return "until " + expiry.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Helpers

    /// Moves the folder of a version before 3 (`~/.claude-desktop-swap`, from when this app was
    /// called Claude Account Swap) to its new place once no Claude window runs on a folder inside
    /// it, and leaves a link at the old place, so this process and any older copy of the tool still
    /// find everything there. Expects the lock to be held.
    func moveOldHome() {
        let fm = FileManager.default
        guard let newHome = layout.newHome, Files.isRealDirectory(layout.home), !Files.exists(newHome) else { return }
        let folders = (try? fm.contentsOfDirectory(at: layout.accountsRoot, includingPropertiesForKeys: nil)) ?? []
        guard !folders.contains(where: { claude.pid(usingDataFolder: $0) != nil }) else { return }
        do {
            try fm.moveItem(at: layout.home, to: newHome)
        } catch {
            return log("Couldn't move \(layout.home.path) to \(newHome.path): \(error.localizedDescription)")
        }
        do {
            try fm.createSymbolicLink(at: layout.home, withDestinationURL: newHome)
        } catch {
            // Without the link this process would start a new, empty folder at the old place.
            try? fm.moveItem(at: newHome, to: layout.home)
            return log("Couldn't link \(layout.home.path) to \(newHome.path), so it stays: \(error.localizedDescription)")
        }
        // The log was called swap.log. Lines written here since this version started follow its history.
        let oldLog = newHome.appendingPathComponent("swap.log")
        let newLog = newHome.appendingPathComponent(layout.logFile.lastPathComponent)
        if Files.exists(oldLog) {
            if let recent = try? Data(contentsOf: newLog), let handle = try? FileHandle(forWritingTo: oldLog) {
                handle.seekToEndOfFile()
                handle.write(recent)
                try? handle.close()
                try? fm.removeItem(at: newLog)
            }
            if !Files.exists(newLog) { try? fm.moveItem(at: oldLog, to: newLog) }
        }
        log("Claude Account Swap is now Claude Multi-Accounts: moved \(layout.home.path) to \(newHome.path), "
            + "leaving a link at the old place.")
    }

    /// Accounts signed in to in a new window join the list as soon as Claude records which
    /// account it is. Expects the lock to be held.
    func adoptNewWindows() {
        var accounts = self.accounts()
        let main = try? mainState()
        var changed = false
        for window in newWindows() {
            guard Login.expiry(in: window.folder) != nil, let uuid = Login.accountUUID(in: window.folder) else { continue }
            let folderName = window.folder.lastPathComponent
            if let index = accounts.firstIndex(where: { $0.uuid == uuid }) {
                // Signed in again to an account already in the list: the new sign-in replaces its old folder.
                let old = layout.folder(of: accounts[index])
                if claude.pid(usingDataFolder: old) != nil { continue }
                if !(main?.signedIn == true && main?.uuid == uuid) { try? returnSessions(of: accounts[index]) }
                accounts[index].folder = folderName
                accounts[index].savedAt = Registry.now()
                if Files.exists(old) { try? moveToTrash(old) }
                log("“\(accounts[index].name)” was signed in to again in a new window; its earlier folder went to the Trash")
            } else {
                let name = uniqueName(window.name ?? accounts.defaultName(), among: accounts)
                accounts.append(Account(uuid: uuid, name: name, savedAt: Registry.now(), folder: folderName))
                log("New account “\(name)” (\(uuid)), signed in to in its own window")
            }
            try? FileManager.default.removeItem(at: window.folder.appendingPathComponent(Self.newWindowMarker))
            changed = true
        }
        if changed { try? saveAccounts(accounts) }
    }

    /// The saved account after the one in the main Claude, so switching without a name rotates.
    func nextAccount(_ accounts: [Account], main: MainState) throws -> Account {
        let ready = accounts.filter {
            $0.uuid != main.uuid && Login.hasSignIn(in: layout.folder(of: $0))
                && claude.pid(usingDataFolder: layout.folder(of: $0)) == nil
        }
        guard !ready.isEmpty else { throw SwapError.noOtherAccount }
        guard let start = accounts.firstIndex(where: { $0.uuid == main.uuid }) else { return ready[0] }
        let ordered = accounts[(start + 1)...] + accounts[..<start]
        return ordered.first { candidate in ready.contains { $0.uuid == candidate.uuid } } ?? ready[0]
    }

    /// The main Claude's account must not also be open in its own window: saving its sign-in
    /// would write over the folder that window runs on.
    func refuseIfSignedInTwice(_ accounts: [Account], main: MainState) throws {
        guard main.signedIn, let account = accounts.first(where: { $0.uuid == main.uuid }) else { return }
        if claude.pid(usingDataFolder: layout.folder(of: account)) != nil {
            throw SwapError.signedInTwice(account.name)
        }
    }

    /// Saves the main Claude's sign-in under its account. Returns that account, or nil when there
    /// is nothing to save.
    @discardableResult
    func saveLive(_ accounts: inout [Account], nameForCurrent: String?) throws -> Account? {
        let main = try mainState()
        guard main.signedIn else {
            log("Claude is signed out; nothing to save")
            return nil
        }
        guard let uuid = main.uuid else {
            log("Claude is signed in but hasn't recorded which account yet; kept a backup only. "
                + "Open Claude, let it finish loading, then switch again to save this account.")
            return nil
        }
        let index: Int
        if let existing = accounts.firstIndex(where: { $0.uuid == uuid }) {
            index = existing
        } else {
            let name = uniqueName(nameForCurrent ?? accounts.defaultName(), among: accounts)
            accounts.append(Account(uuid: uuid, name: name))
            index = accounts.count - 1
            log("New account “\(name)” (\(uuid))")
        }
        let folder = layout.folder(of: accounts[index])
        if claude.pid(usingDataFolder: folder) != nil { throw SwapError.signedInTwice(accounts[index].name) }
        try Files.privateFolder(layout.accountsRoot)
        try Login.copy(from: layout.liveData, to: folder)
        accounts[index].savedAt = Registry.now()
        try saveAccounts(accounts)
        log("Saved the sign-in of “\(accounts[index].name)”")
        return accounts[index]
    }

    /// Copies the main Claude's sign-in to `backups/`, keeping the last 20.
    func backUpLive(_ reason: String) {
        guard Login.hasSignIn(in: layout.liveData) else { return }
        do {
            let root = try Files.privateFolder(layout.backupsRoot)
            try Login.copy(from: layout.liveData, to: root.appendingPathComponent("\(Self.backupStamp.string(from: Date()))-\(reason)"))
            let old = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { !$0.hasPrefix(".") }.sorted().dropLast(Self.keepBackups)
            for name in old { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        } catch {
            log("Couldn't back up the live sign-in: \(error.localizedDescription)")
        }
    }

    func quitMain(_ progress: (String) -> Void) throws {
        guard let pid = claude.mainPID() else { return }
        progress("Quitting Claude…")
        log("Quitting Claude")
        try claude.quit(pid: pid, timeout: quitTimeout)
        settle()
    }

    /// Claude may restart itself (after an update, say); its files are never changed while it runs.
    func ensureMainQuit() throws {
        if claude.mainPID() != nil { throw SwapError.claudeRestarted }
    }

    /// Runs the steps before the live sign-in changes; if one fails, Claude is opened again as it was.
    func reopeningOnFailure(_ steps: () throws -> Void) throws {
        let wasRunning = claude.mainPID() != nil
        do {
            try steps()
        } catch {
            if wasRunning && claude.mainPID() == nil { try? launchMain() }
            throw error
        }
    }

    func launchMain() throws {
        log("Opening Claude")
        try claude.launchMain(app: layout.claudeApp)
    }

    func settle() {
        if settleDelay > 0 { Thread.sleep(forTimeInterval: settleDelay) }
    }

    func requireClaude() throws {
        guard Files.exists(layout.claudeApp) else { throw SwapError.claudeNotInstalled(layout.claudeApp.path) }
    }

    func validName(_ name: String, among accounts: [Account], ignoring uuid: String?) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SwapError.emptyName }
        if accounts.contains(where: { $0.uuid != uuid && $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            throw SwapError.nameTaken(clean)
        }
        return clean
    }

    func uniqueName(_ name: String, among accounts: [Account]) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = base.isEmpty ? accounts.defaultName() : base
        var n = 2
        while accounts.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    func saveAccounts(_ accounts: [Account]) throws {
        try Files.privateFolder(layout.home)
        try Registry.save(accounts, to: layout.accountsFile)
    }

    /// Runs `body` holding `<home>/.lock`, so the app and the command never change things at once.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try Files.privateFolder(layout.home)
        let fd = open(layout.lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw SwapError.io("Can't open \(layout.lockFile.path).") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SwapError.busy }
        return try body()
    }

    static func appendLog(_ message: String, to url: URL) {
        _ = try? Files.privateFolder(url.deletingLastPathComponent())
        let line = "[\(Registry.now())] \(message)\n"
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
