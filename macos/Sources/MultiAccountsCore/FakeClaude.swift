import Foundation

/// A pretend Claude for the demo and the tests: it remembers which data folders are "open" and
/// starts nothing.
public final class SimulatedClaude: ClaudeControl, @unchecked Sendable {
    private let lock = NSLock()
    private var main: pid_t?
    private var windows: [String: pid_t] = [:]
    private var nextPID: pid_t = 41_001
    private let liveData: URL

    /// How long quitting takes.
    public var quitDelay: TimeInterval = 0
    /// Makes quitting fail, like a Claude stuck on a "Quit anyway?" prompt.
    public var refusesToQuit = false
    /// Called when a copy starts on a data folder without a sign-in, to play the person signing in.
    public var signIn: ((URL) -> Void)?

    public init(liveData: URL) {
        self.liveData = liveData
    }

    public func mainPID() -> pid_t? {
        lock.withLock { main }
    }

    public func pid(usingDataFolder dataFolder: URL) -> pid_t? {
        lock.withLock { windows[SystemClaudeControl.canonical(dataFolder.path)] }
    }

    public func anyInstanceRunning() -> Bool {
        lock.withLock { main != nil || !windows.isEmpty }
    }

    public func quit(pid: pid_t, timeout: TimeInterval) throws {
        if refusesToQuit { throw SwapError.claudeDidNotQuit }
        Thread.sleep(forTimeInterval: quitDelay)
        lock.withLock {
            if main == pid { main = nil }
            windows = windows.filter { $0.value != pid }
        }
    }

    public func launchMain(app: URL) throws {
        lock.withLock { main = takePID() }
        if !Login.hasSignIn(in: liveData) { signIn?(liveData) }
    }

    public func launchSide(app: URL, dataFolder: URL) throws {
        lock.withLock { windows[SystemClaudeControl.canonical(dataFolder.path)] = takePID() }
        if !Login.hasSignIn(in: dataFolder) { signIn?(dataFolder) }
    }

    public func activate(pid: pid_t) {}

    private func takePID() -> pid_t {
        defer { nextPID += 1 }
        return nextPID
    }
}

/// A pretend Claude whose state is files, so separate runs of the command line tool share it.
/// Used by the command's end-to-end tests through `CMA_FAKE_APP`:
///
///     <CMA_FAKE_APP>            exists while the main Claude "runs"
///     <CMA_FAKE_APP>.windows/   one file per side-by-side window, holding its data folder
///
/// `CMA_FAKE_QUIT_DELAY` slows quitting down and `CMA_FAKE_APP_STUCK` makes the main Claude refuse.
public final class FileClaudeControl: ClaudeControl {
    let marker: URL
    let environment: [String: String]
    static let mainFakePID: pid_t = 90_000

    public init(marker: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.marker = marker
        self.environment = environment
    }

    private var windowsFolder: URL { URL(fileURLWithPath: marker.path + ".windows", isDirectory: true) }

    private func windows() -> [(pid: pid_t, file: URL, folder: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: windowsFolder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard let folder = try? String(contentsOf: file, encoding: .utf8), let pid = pid_t(file.lastPathComponent)
            else { return nil }
            return (pid, file, folder)
        }
    }

    public func mainPID() -> pid_t? {
        Files.exists(marker) ? Self.mainFakePID : nil
    }

    public func pid(usingDataFolder dataFolder: URL) -> pid_t? {
        let wanted = SystemClaudeControl.canonical(dataFolder.path)
        return windows().first { $0.folder == wanted }?.pid
    }

    public func anyInstanceRunning() -> Bool {
        mainPID() != nil || !windows().isEmpty
    }

    public func quit(pid: pid_t, timeout: TimeInterval) throws {
        guard pid == Self.mainFakePID else {
            for window in windows() where window.pid == pid { try? FileManager.default.removeItem(at: window.file) }
            return
        }
        Thread.sleep(forTimeInterval: Double(environment["CMA_FAKE_QUIT_DELAY"] ?? "") ?? 0)
        if environment["CMA_FAKE_APP_STUCK"] != nil {
            Thread.sleep(forTimeInterval: timeout)
            throw SwapError.claudeDidNotQuit
        }
        try? FileManager.default.removeItem(at: marker)
    }

    public func launchMain(app: URL) throws {
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    public func launchSide(app: URL, dataFolder: URL) throws {
        try FileManager.default.createDirectory(at: windowsFolder, withIntermediateDirectories: true)
        let pid = (windows().map(\.pid).max() ?? 90_000) + 1
        try Data(SystemClaudeControl.canonical(dataFolder.path).utf8)
            .write(to: windowsFolder.appendingPathComponent(String(pid)))
    }

    public func activate(pid: pid_t) {}
}
