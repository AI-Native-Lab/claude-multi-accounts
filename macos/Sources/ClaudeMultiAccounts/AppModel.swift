import AppKit
import MultiAccountsCore

// The model only touches the manager on its serial queues: `work` for anything that changes
// accounts or starts Claude, `sizeQueue` for measuring folders, which changes nothing.
extension AccountManager: @unchecked Sendable {}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var problem: String?
    @Published private(set) var busy: String?
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published var showingSettings = false

    let isDemo: Bool
    let manager: AccountManager
    let settings: AppSettings
    private let work = DispatchQueue(label: "claude-multi-accounts.work")
    private let sizeQueue = DispatchQueue(label: "claude-multi-accounts.sizes")
    private var timers: [Timer] = []

    init(manager: AccountManager, settings: AppSettings, isDemo: Bool) {
        self.manager = manager
        self.settings = settings
        self.isDemo = isDemo
    }

    /// Starts keeping the state up to date: every 3 seconds, and folder sizes every 10 minutes.
    func start() {
        refresh()
        refreshSizes()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
            Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshSizes() }
            },
        ]
    }

    var statuses: [AccountStatus] { snapshot?.accounts ?? [] }
    var mainName: String? { snapshot?.mainAccount?.account.name }

    var headline: String {
        guard let snapshot else { return problem == nil ? "Claude Multi-Accounts" : "Claude isn't set up yet" }
        if !snapshot.main.signedIn { return "Claude is signed out" }
        return "Claude: \(mainName ?? "an unnamed account")"
    }

    var subheadline: String {
        guard let snapshot else { return problem ?? "" }
        var parts: [String] = [snapshot.main.running ? "Running" : "Not open"]
        if snapshot.main.signedIn { parts.append("signed in \(Self.describe(snapshot.main.loginExpires))") }
        let windows = statuses.filter { $0.place == .window }.count
        if windows > 0 { parts.append(windows == 1 ? "1 account side by side" : "\(windows) accounts side by side") }
        return parts.joined(separator: " · ")
    }

    func refresh() {
        work.async { [manager] in
            let result = Result { try manager.snapshot() }
            Task { @MainActor in
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.problem = nil
                case .failure(let error):
                    self.snapshot = nil
                    self.problem = error.localizedDescription
                }
            }
        }
    }

    /// Reads everything at once and waits for it; used before drawing screenshots.
    func refreshNow() {
        snapshot = work.sync { try? manager.snapshot() }
        sizes = sizeQueue.sync { Self.readSizes(manager) }
    }

    func refreshSizes() {
        sizeQueue.async { [manager] in
            let sizes = Self.readSizes(manager)
            Task { @MainActor in self.sizes = sizes }
        }
    }

    private nonisolated static func readSizes(_ manager: AccountManager) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for status in (try? manager.snapshot().accounts) ?? [] {
            sizes[status.account.uuid] = manager.folderSize(of: status)
        }
        return sizes
    }

    // MARK: - Actions

    func switchTo(_ status: AccountStatus) {
        if status.place == .main { return openMain() }
        guard let nameForCurrent = nameForMainAccount() else { return }
        let name = status.account.name
        var closeWindow = false
        if status.place == .window {
            guard Prompt.confirm(
                title: "Switch the main Claude to “\(name)”?",
                message: "“\(name)” is open in its own window. That window closes first, so its sign-in is only in one place. Then Claude quits and reopens signed in to “\(name)”; Code sessions that are running stop.",
                button: "Close Window and Switch") else { return }
            closeWindow = true
        } else if settings.askBeforeSwitching {
            var dontAsk = false
            guard Prompt.confirm(
                title: "Switch Claude to “\(name)”?",
                message: "Claude quits and reopens signed in to “\(name)” a few seconds later. Code sessions that are running stop; you can reopen them afterwards. If Claude asks to confirm quitting, confirm.",
                button: "Switch", suppressible: true, dontAskAgain: &dontAsk) else { return }
            if dontAsk { settings.askBeforeSwitching = false }
        }
        perform("Switching to \(name)…") { manager, progress in
            try manager.switchTo(status.account.uuid, nameForCurrent: nameForCurrent,
                                 closeWindow: closeWindow, progress: progress)
        }
    }

    func openWindow(_ status: AccountStatus) {
        perform("Opening \(status.account.name)…") { manager, _ in
            try manager.openWindow(status.account.uuid)
        }
    }

    func closeWindow(_ status: AccountStatus) {
        perform("Closing \(status.account.name)…") { manager, _ in
            try manager.closeWindow(status.account.uuid)
        }
    }

    func showWindow(_ status: AccountStatus) {
        if let pid = status.windowPID { manager.activate(pid: pid) }
    }

    func addInWindow() {
        guard let name = Prompt.text(
            title: "Sign in to another account",
            message: "A new Claude window opens at its sign-in screen; the main Claude keeps running. Sign in there, and the account joins this list.\n\nName for the account (optional; your email works well):",
            placeholder: "For example: Work", button: "Open Window", allowEmpty: true
        ) else { return }
        perform("Opening a new window…") { manager, _ in
            _ = try manager.addInWindow(name: name.isEmpty ? nil : name)
        }
    }

    func addInMain() {
        guard Prompt.confirm(
            title: "Sign in to another account in the main Claude?",
            message: "Claude quits and reopens signed out, so you can sign in with another account. \(mainName.map { "“\($0)” stays saved. " } ?? "")Code sessions that are running stop.\n\nTip: never use Claude's own Log out. It ends that sign-in for good, so its saved copy stops working.",
            button: "Continue"
        ), let nameForCurrent = nameForMainAccount() else { return }
        perform("Reopening Claude signed out…") { manager, progress in
            try manager.addInMain(nameForCurrent: nameForCurrent, progress: progress)
        }
    }

    func nameMainAccount() {
        guard let name = Prompt.text(
            title: "Name this account",
            message: "Claude is signed in to an account this app hasn't seen yet. Give it a name (your email works well):",
            placeholder: "For example: Personal") else { return }
        perform(nil) { manager, _ in try manager.rename("current", to: name) }
    }

    func rename(_ status: AccountStatus) {
        guard let name = Prompt.text(title: "Rename “\(status.account.name)”", message: "New name:",
                                     placeholder: status.account.name, initial: status.account.name)
        else { return }
        perform(nil) { manager, _ in try manager.rename(status.account.uuid, to: name) }
    }

    func remove(_ status: AccountStatus) {
        guard Prompt.confirm(
            title: "Remove “\(status.account.name)”?",
            message: "Its folder, with its saved sign-in and its own window's data, goes to the Trash, where you can still get it back. The account itself is not touched; to use it here again, sign in to it again.",
            button: "Move to Trash"
        ) else { return }
        perform(nil) { manager, _ in try manager.remove(status.account.uuid) }
    }

    func openMain() {
        perform(nil) { manager, _ in try manager.openMain() }
    }

    func openNewWindow(_ window: NewWindow) {
        perform(nil) { manager, _ in try manager.openNewWindow(window) }
    }

    func closeNewWindow(_ window: NewWindow) {
        perform("Closing the window…") { manager, _ in try manager.closeNewWindow(window) }
    }

    func discardNewWindow(_ window: NewWindow) {
        perform(nil) { manager, _ in try manager.discardNewWindow(window) }
    }

    func showFolder(_ status: AccountStatus) {
        NSWorkspace.shared.activateFileViewerSelecting([status.folder])
    }

    func showAccountsFolder() {
        try? FileManager.default.createDirectory(at: manager.layout.accountsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([manager.layout.accountsRoot])
    }

    func showClaudeDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([manager.layout.liveData])
    }

    func openLog() {
        let log = manager.layout.logFile
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            Prompt.info(title: "No activity yet", message: "The log starts with the first change to an account.")
        }
    }

    // MARK: - The command line tool

    /// The command inside this app, which `Install Command` links into ~/.local/bin.
    var bundledCommand: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "claude-multi-accounts")
    }

    var installedCommand: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude-multi-accounts")
    }

    var commandInstalled: Bool {
        guard let bundled = bundledCommand,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: installedCommand.path) else { return false }
        return target == bundled.path
    }

    func installCommand() {
        guard let bundled = bundledCommand else {
            Prompt.info(title: "Not available", message: "This copy of the app has no command line tool inside it.")
            return
        }
        objectWillChange.send()
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: installedCommand.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: installedCommand.path)) != nil || fm.fileExists(atPath: installedCommand.path) {
                try fm.removeItem(at: installedCommand)
            }
            try fm.createSymbolicLink(at: installedCommand, withDestinationURL: bundled)
            // Before version 3 the app was called Claude Account Swap and its command
            // claude-desktop-swap; that link leads nowhere once the old app is gone.
            let oldLink = installedCommand.deletingLastPathComponent().appendingPathComponent("claude-desktop-swap")
            if let target = try? fm.destinationOfSymbolicLink(atPath: oldLink.path),
               target.hasSuffix(".app/Contents/MacOS/claude-desktop-swap"), !fm.fileExists(atPath: target) {
                try? fm.removeItem(at: oldLink)
            }
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                .contains { $0 == installedCommand.deletingLastPathComponent().path }
            Prompt.info(title: "Installed claude-multi-accounts",
                        message: "Linked \(installedCommand.path) to the copy inside this app, so it stays up to date with the app."
                            + (onPath ? "" : "\n\nAdd ~/.local/bin to your PATH to run it by name:\necho 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc"))
        } catch {
            Prompt.error(error)
        }
    }

    // MARK: - Helpers

    static func describe(_ expiry: Date?) -> String {
        guard let expiry else { return "sign-in expired" }
        if expiry == .distantFuture { return "until Claude quits" }
        return "until " + expiry.formatted(.dateTime.day().month(.abbreviated))
    }

    /// When the main Claude holds an account this app hasn't named, asks for a name, so the list
    /// reads well after switching. Returns "" to use a default name, or nil when cancelled.
    private func nameForMainAccount() -> String? {
        guard snapshot?.mainIsUnnamed == true else { return "" }
        return Prompt.text(
            title: "Name the account Claude is signed in to now",
            message: "It is saved under this name when Claude switches away from it (your email works well). Leave it empty for a default name.",
            placeholder: "For example: Personal", button: "Continue", allowEmpty: true)
    }

    private func perform(_ label: String?,
                         _ action: @escaping (AccountManager, @escaping (String) -> Void) throws -> Void) {
        guard busy == nil else { return }
        busy = label ?? "Working…"
        work.async { [manager] in
            let progress = Self.progressSink { self.busy = $0 }
            var failure: Error?
            do { try action(manager, progress) } catch { failure = error }
            Task { @MainActor in
                self.busy = nil
                self.refresh()
                self.refreshSizes()
                if let failure { Prompt.error(failure) }
            }
        }
    }

    private nonisolated static func progressSink(_ update: @escaping @MainActor (String) -> Void) -> (String) -> Void {
        { message in Task { @MainActor in update(message) } }
    }
}
