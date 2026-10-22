import MultiAccountsCore
import Foundation

// claude-multi-accounts: keep several accounts signed in to the Claude desktop app and use them at
// the same time, each in its own Claude window, or switch the main Claude between them. The same
// engine as Claude Multi-Accounts.app.

let usage = """
    claude-multi-accounts: use several Claude accounts at the same time in the Claude desktop app

      list [--json]                    accounts, where each one is open, sign-in expiry (alias: status)
      open ACCOUNT                     open ACCOUNT in its own Claude window, next to the main one
      close ACCOUNT                    quit ACCOUNT's own window
      add --window [--name NAME]       sign in to another account in a new window; the main Claude keeps running
      switch [ACCOUNT] [--name-current NAME] [--close-window]
                                       put ACCOUNT (default: the next one) in the main Claude, which restarts;
                                       --close-window first closes ACCOUNT's own window if it is open
      add [--name-current NAME]        save the main Claude's account and reopen Claude signed out
      rename ACCOUNT NAME              rename an account (`current` = the main Claude's account)
      remove ACCOUNT [--yes]           forget ACCOUNT: its folder goes to the Trash
      doctor                           check that this Mac's Claude looks as expected
      paths                            where everything is kept

    ACCOUNT is a number or a name from `list`, or a uuid.
    """

let environment = ProcessInfo.processInfo.environment
var arguments = Array(CommandLine.arguments.dropFirst())

// The detached worker (see runDetached) is marked by hidden first arguments rather than the
// environment, which Claude would hand down to its Code tab after the worker reopens it.
//   __detach <result> <command…>   the middle step: start the worker, then leave at once
//   __work <result> <command…>     the worker: do the command, write its outcome to <result>
var workerResult: URL?
if arguments.count >= 2, arguments[0] == "__detach" {
    _ = try? spawn(arguments: ["__work"] + arguments.dropFirst(), output: Layout.system().logFile)
    exit(0)
}
if arguments.count >= 2, arguments[0] == "__work" {
    workerResult = URL(fileURLWithPath: arguments[1])
    arguments.removeFirst(2)
}

var layout = Layout.system()
let fakeApp = environment["CMA_FAKE_APP"].map { URL(fileURLWithPath: $0) }
let claude: ClaudeControl
if let fakeApp {
    // Tests: a pretend Claude made of files, and a pretend Trash.
    claude = FileClaudeControl(marker: fakeApp)
    layout.claudeApp = fakeApp.deletingLastPathComponent()
    if layout.trash == nil { layout.trash = layout.home.appendingPathComponent("Trash", isDirectory: true) }
} else {
    claude = SystemClaudeControl()
}
let manager = AccountManager(layout: layout, claude: claude)
manager.quitTimeout = Double(environment["CMA_QUIT_TIMEOUT"] ?? "") ?? 90
if fakeApp != nil { manager.settleDelay = 0 }

// MARK: - Arguments

struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    static let takesValue: Set<String> = ["--name-current", "--name"]

    init(_ raw: [String]) throws {
        var rest = raw[...]
        while let arg = rest.popFirst() {
            if Self.takesValue.contains(arg) {
                guard let value = rest.popFirst() else { throw SwapError.io("\(arg) needs a value.") }
                values[arg] = value
            } else if let eq = arg.firstIndex(of: "="), Self.takesValue.contains(String(arg[..<eq])) {
                values[String(arg[..<eq])] = String(arg[arg.index(after: eq)...])
            } else if arg.hasPrefix("-") && arg.count > 1 {
                flags.insert(arg == "-y" ? "--yes" : arg)
            } else {
                positional.append(arg)
            }
        }
    }

    func one(_ what: String) throws -> String {
        guard let first = positional.first else { throw SwapError.io("Which \(what)? See `claude-multi-accounts help`.") }
        return first
    }
}

// MARK: - Commands

func list(json: Bool) throws {
    let snapshot = try manager.snapshot()
    let main = snapshot.main
    if json {
        let current: Any = main.signedIn
            ? ["uuid": main.uuid as Any? ?? NSNull(), "name": snapshot.mainAccount?.account.name as Any? ?? NSNull()]
            : NSNull()
        let accounts: [[String: Any]] = snapshot.accounts.map { status in
            [
                "number": status.number,
                "uuid": status.account.uuid,
                "name": status.account.name,
                "active": status.place == .main,
                "saved": status.hasSavedSignIn,
                "savedAt": status.account.savedAt as Any? ?? NSNull(),
                "loginExpires": isoExpiry(status.loginExpires),
                "place": status.place.rawValue,
                "window": status.windowPID != nil,
                "folder": status.folder.path,
            ]
        }
        let windows: [[String: Any]] = snapshot.newWindows.map {
            ["folder": $0.folder.path, "name": $0.name as Any? ?? NSNull(), "open": $0.pid != nil]
        }
        let object: [String: Any] = ["running": main.running, "signedIn": main.signedIn, "current": current,
                                     "accounts": accounts, "newWindows": windows]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        return
    }

    let state = main.running ? "running" : "not running"
    if !main.signedIn {
        print("Main Claude (\(state)): signed out")
    } else if let account = snapshot.mainAccount {
        print("Main Claude (\(state)): signed in as “\(account.account.name)”")
    } else {
        print("Main Claude (\(state)): signed in to an account that isn't named yet "
              + "(name it with: claude-multi-accounts rename current \"NAME\")")
    }
    if snapshot.accounts.isEmpty {
        print("\nNo saved accounts yet. Run `claude-multi-accounts add --window` to sign in to another account")
        print("in its own window, or `claude-multi-accounts add` to sign in to it in the main Claude.")
    } else {
        let width = snapshot.accounts.map(\.account.name.count).max() ?? 0
        print()
        for status in snapshot.accounts {
            let mark = status.place == .main ? "→" : status.place == .window ? "◫" : " "
            let note: String
            switch status.place {
            case .main:
                note = "main Claude, login valid \(AccountManager.describe(status.loginExpires))"
                    + (status.isSignedInTwice ? " (also open in its own window)" : "")
            case .window: note = "open in its own window, login valid \(AccountManager.describe(status.loginExpires))"
            case .saved: note = "login valid \(AccountManager.describe(status.loginExpires))"
            case .notSaved: note = "not saved yet (saved when you switch away from it)"
            }
            let name = status.account.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print(" \(mark) \(status.number). \(name)  \(note)")
        }
    }
    for window in snapshot.newWindows {
        print("\n A new window is \(window.pid != nil ? "open" : "closed") to sign in to "
              + "\(window.name.map { "“\($0)”" } ?? "another account"); it joins the list once signed in.")
    }
}

func isoExpiry(_ date: Date?) -> Any {
    guard let date else { return NSNull() }
    if date == .distantFuture { return "session" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.string(from: date)
}

func switchAccount(_ args: Arguments) throws {
    // Settle what can be told at once here, so mistakes don't wait for the worker.
    let snapshot = try manager.snapshot()
    let query = args.positional.first.flatMap { $0 == "next" ? nil : $0 }
    let others = snapshot.accounts.filter {
        $0.place != .main && $0.hasSavedSignIn && ($0.windowPID == nil || query != nil)
    }
    if let query {
        let target = try manager.find(query)
        guard let status = snapshot.accounts.first(where: { $0.account.uuid == target.uuid }) else { return }
        if status.place == .main {
            try manager.openMain()
            print("Already signed in as “\(target.name)”.")
            return
        }
        guard status.hasSavedSignIn else { throw SwapError.notSavedYet(target.name) }
        if status.windowPID != nil && !args.flags.contains("--close-window") {
            throw SwapError.io("“\(target.name)” is open in its own Claude window. Close it first "
                               + "(claude-multi-accounts close \(status.number)), or add --close-window.")
        }
    } else if others.isEmpty {
        throw SwapError.noOtherAccount
    }
    print(try inWorker {
        notify("Switching Claude…")
        return try manager.switchTo(query, nameForCurrent: args.values["--name-current"],
                                    closeWindow: args.flags.contains("--close-window"),
                                    progress: { manager.log($0) })
    })
}

func add(_ args: Arguments) throws {
    if args.flags.contains("--window") {
        let folder = try manager.addInWindow(name: args.values["--name"] ?? args.positional.first)
        print("A new Claude window opened. Sign in there with your other account; the main Claude keeps running.")
        print("The account joins the list once it has signed in (its folder: \(folder.path)).")
        return
    }
    print(try inWorker {
        try manager.addInMain(nameForCurrent: args.values["--name-current"], progress: { manager.log($0) })
    })
}

func remove(_ args: Arguments) throws {
    let account = try manager.find(try args.one("account"))
    if !args.flags.contains("--yes") {
        guard isatty(STDIN_FILENO) != 0 else { throw SwapError.io("Add --yes to confirm.") }
        Swift.print("Forget the saved sign-in of “\(account.name)”? Its folder goes to the Trash. [y/N] ", terminator: "")
        guard let answer = readLine(), ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased()) else {
            print("Kept it.")
            return
        }
    }
    print(try manager.remove(account.uuid))
}

func doctor() {
    for check in manager.doctor() {
        print("\(check.ok ? "ok " : "BAD")  \(check.name): \(check.value)")
    }
}

func paths() {
    print("Claude data folder (main Claude):  \(layout.liveData.path)")
    print("This tool's folder:                \(layout.home.path)")
    print("Activity log:                      \(layout.logFile.path)")
    for account in manager.accounts() {
        print("  \(account.name): \(layout.folder(of: account).path)")
    }
}

// MARK: - The detached worker

/// Runs `action` in a process that is no child of Claude, and waits for its outcome.
///
/// Quitting Claude ends everything it started, including a terminal in its Code tab. The work is
/// handed to a process started through a middle step that exits at once, so launchd adopts it and
/// the switch finishes even though this process dies with Claude.
func inWorker(_ action: () throws -> String) throws -> String {
    guard let workerResult else { return try runDetached() }
    var message: String
    var ok = true
    do {
        message = try action()
    } catch {
        message = error.localizedDescription
        ok = false
    }
    manager.log((ok ? "Done: " : "Failed: ") + message)
    notify(message)
    let data = try JSONSerialization.data(withJSONObject: ["ok": ok, "message": message])
    try data.write(to: workerResult, options: .atomic)
    if !ok { throw SwapError.io(message) }
    return message
}

func runDetached() throws -> String {
    try FileManager.default.createDirectory(at: layout.runsRoot, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    for old in (try? FileManager.default.contentsOfDirectory(at: layout.runsRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
        let modified = (try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if modified < Date().addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: old) }
    }
    let result = layout.runsRoot.appendingPathComponent("\(UUID().uuidString).json")
    let middle = try spawn(arguments: ["__detach", result.path] + arguments, output: layout.logFile)
    var status: Int32 = 0
    waitpid(middle, &status, 0)

    let deadline = Date().addingTimeInterval(manager.quitTimeout + 60)
    while Date() < deadline {
        if let data = try? Data(contentsOf: result),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try? FileManager.default.removeItem(at: result)
            let message = object["message"] as? String ?? ""
            guard object["ok"] as? Bool == true else { throw SwapError.io(message) }
            return message
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw SwapError.io("The switch is taking too long; see \(layout.logFile.path)")
}

/// Starts this command again in a new session, with its output going to `output`.
func spawn(arguments: [String], output: URL) throws -> pid_t {
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, output.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)

    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    let code = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
    guard code == 0 else { throw SwapError.io("Couldn't start the switch: \(String(cString: strerror(code)))") }
    return pid
}

func notify(_ message: String) {
    guard fakeApp == nil else { return }
    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/osascript"),
                         arguments: ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"Claude Multi-Accounts\"",
                                     "-e", "end run", message])
}

// MARK: - Main

func main() -> Int32 {
    var raw = arguments
    let command = raw.isEmpty ? "list" : raw.removeFirst()
    do {
        let args = try Arguments(raw)
        switch command {
        case "list", "status": try list(json: args.flags.contains("--json"))
        case "switch": try switchAccount(args)
        case "add": try add(args)
        case "open": print(try manager.openWindow(try args.one("account")))
        case "close": print(try manager.closeWindow(try args.one("account")))
        case "rename":
            guard args.positional.count == 2 else { throw SwapError.io("Usage: claude-multi-accounts rename ACCOUNT NAME") }
            try manager.rename(args.positional[0], to: args.positional[1])
            print("Named it “\(args.positional[1].trimmingCharacters(in: .whitespaces))”.")
        case "remove": try remove(args)
        case "doctor": doctor()
        case "paths": paths()
        case "help", "-h", "--help": print(usage)
        default:
            FileHandle.standardError.write(Data("Unknown command “\(command)”.\n\n\(usage)\n".utf8))
            return 2
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

exit(main())
