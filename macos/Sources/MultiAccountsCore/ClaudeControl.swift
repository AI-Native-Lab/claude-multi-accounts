import AppKit
import Darwin
import Foundation

/// Everything the account manager needs from the running system. Tests and the demo swap in a fake.
public protocol ClaudeControl: AnyObject {
    /// The main Claude: the copy running on Claude's own data folder.
    func mainPID() -> pid_t?
    /// The Claude window started on `dataFolder`, if one is running.
    func pid(usingDataFolder dataFolder: URL) -> pid_t?
    /// Whether any copy of Claude runs, main or side by side.
    func anyInstanceRunning() -> Bool
    /// Whether Claude's updater runs: it waits for every copy of Claude to quit, then installs an
    /// update and opens the main Claude again.
    func updaterRunning() -> Bool
    /// Asks one copy of Claude to quit, like ⌘Q in it, and waits until it has.
    func quit(pid: pid_t, timeout: TimeInterval) throws
    /// Starts the main Claude; `inBackground` leaves the app in front where it is.
    func launchMain(app: URL, inBackground: Bool) throws
    /// Starts another copy of Claude on its own data folder.
    func launchSide(app: URL, dataFolder: URL, inBackground: Bool) throws
    /// Brings a running copy to the front.
    func activate(pid: pid_t)
}

extension ClaudeControl {
    func launchMain(app: URL) throws {
        try launchMain(app: app, inBackground: false)
    }

    func launchSide(app: URL, dataFolder: URL) throws {
        try launchSide(app: app, dataFolder: dataFolder, inBackground: false)
    }
}

/// The real Claude app on this Mac.
///
/// Claude holds no single-instance lock on macOS: `open -n` starts a second copy on the same data
/// folder unless it is given `--user-data-dir`. So the main Claude is the copy started without
/// that switch, and a side-by-side window is the copy whose switch names its folder.
public final class SystemClaudeControl: ClaudeControl {
    public init() {}

    public func mainPID() -> pid_t? {
        Self.instances().first { $0.isMain }?.pid
    }

    public func pid(usingDataFolder dataFolder: URL) -> pid_t? {
        let wanted = Self.canonical(dataFolder.path)
        return Self.instances().first { $0.known && $0.dataFolder.map(Self.canonical) == wanted }?.pid
    }

    public func anyInstanceRunning() -> Bool {
        !Self.instances().isEmpty
    }

    public func updaterRunning() -> Bool {
        Self.processes().contains { $0.path.hasSuffix(ClaudeApp.updaterSuffix) }
    }

    public func quit(pid: pid_t, timeout: TimeInterval) throws {
        guard isAlive(pid) else { return }
        // NSRunningApplication addresses this copy alone; AppleScript's `tell application` would
        // pick any of them. If the quit request can't be sent, SIGTERM makes Electron quit just as
        // gracefully.
        if NSRunningApplication(processIdentifier: pid)?.terminate() != true {
            kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while isAlive(pid) {
            if Date() > deadline { throw SwapError.claudeDidNotQuit }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    public func launchMain(app: URL, inBackground: Bool) throws {
        // With a side-by-side window running, a plain `open` would only bring that one forward.
        var args = ["-a", app.path]
        if anyInstanceRunning() { args.insert("-n", at: 0) }
        if inBackground { args.insert("-g", at: 0) }
        try runOpen(args)
    }

    public func launchSide(app: URL, dataFolder: URL, inBackground: Bool) throws {
        try runOpen((inBackground ? ["-g"] : []) + ["-n", "-a", app.path, "--args", ClaudeApp.userDataSwitch + dataFolder.path])
    }

    public func activate(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func runOpen(_ args: [String]) throws {
        // `open` hands this process's environment to Claude, which hands it to every terminal in
        // its Code tab; keep this tool's own variables out of it.
        let environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMA_") }
        do {
            try run("/usr/bin/open", args, environment: environment)
        } catch {
            throw SwapError.launchFailed(String(describing: error))
        }
    }

    // MARK: - Processes

    struct Instance {
        var pid: pid_t
        /// The `--user-data-dir` it was started with; nil for the main Claude.
        var dataFolder: String?
        /// False when its command line couldn't be read: it is then neither the main Claude nor any
        /// account's window, so nothing is changed on a guess.
        var known = true

        var isMain: Bool { known && dataFolder == nil }
    }

    /// Every running copy of Claude's main executable (helpers and the Code tab's CLI excluded).
    static func instances() -> [Instance] {
        processes().filter { $0.path.hasSuffix(ClaudeApp.executableSuffix) }.map { process in
            guard let args = arguments(of: process.pid) else {
                return Instance(pid: process.pid, dataFolder: nil, known: false)
            }
            let folder = args.dropFirst().last { $0.hasPrefix(ClaudeApp.userDataSwitch) }
                .map { String($0.dropFirst(ClaudeApp.userDataSwitch.count)) }
            return Instance(pid: process.pid, dataFolder: folder)
        }
    }

    /// Every process this user can see, with the path of its executable.
    static func processes() -> [(pid: pid_t, path: String)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: [(pid: pid_t, path: String)] = []
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            result.append((pid, String(cString: path)))
        }
        return result
    }

    /// A process's command line, read with sysctl(KERN_PROCARGS2).
    static func arguments(of pid: pid_t) -> [String]? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // Layout: argc, the executable path, NUL padding, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }
        while i < size && buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// The path with symbolic links resolved, as realpath(3) gives it, for comparing folders.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

struct CommandFailed: Error, CustomStringConvertible {
    var description: String
}

@discardableResult
func run(_ tool: String, _ args: [String], allowFailure: Bool = false, environment: [String: String]? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    if let environment { process.environment = environment }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 || allowFailure else {
        let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw CommandFailed(description: "\(tool) exited with \(process.terminationStatus): \(message)")
    }
    return String(decoding: data, as: UTF8.self)
}
