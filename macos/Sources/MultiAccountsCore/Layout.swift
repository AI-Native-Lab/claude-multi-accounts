import AppKit
import Foundation

/// Where Claude and the saved accounts live on disk.
///
/// The main Claude keeps its sign-in in its own data folder. This tool keeps one folder per
/// account under `<home>/accounts/`, holding that account's sign-in while it isn't in the main
/// Claude. The same folder is the data folder of the account's own Claude window when it is open
/// side by side, so its sign-in is only ever in one place.
public struct Layout {
    /// Claude's data folder, used by the main Claude.
    public var liveData: URL
    /// This tool's folder: the account list, each account's folder, backups and the log.
    public var home: URL
    public var claudeApp: URL
    /// Where removed account folders go. Nil means the Trash.
    public var trash: URL?
    /// Set while `home` is still the folder of a version before 3, when this app was called Claude
    /// Account Swap: where it moves once no Claude window runs on it (see `AccountManager.moveOldHome`).
    public var newHome: URL?

    public init(liveData: URL, home: URL, claudeApp: URL, trash: URL? = nil, newHome: URL? = nil) {
        self.liveData = liveData
        self.home = home
        self.claudeApp = claudeApp
        self.trash = trash
        self.newHome = newHome
    }

    public var accountsFile: URL { home.appendingPathComponent("accounts.json") }
    public var accountsRoot: URL { home.appendingPathComponent("accounts", isDirectory: true) }
    public var backupsRoot: URL { home.appendingPathComponent("backups", isDirectory: true) }
    public var runsRoot: URL { home.appendingPathComponent("runs", isDirectory: true) }
    public var logFile: URL { home.appendingPathComponent("activity.log") }
    var lockFile: URL { home.appendingPathComponent(".lock") }

    /// An account's own folder.
    public func folder(of account: Account) -> URL {
        accountsRoot.appendingPathComponent(account.folder ?? account.uuid, isDirectory: true)
    }

    /// The real layout of the current user. `CMA_CLAUDE_DIR`, `CMA_HOME` and `CMA_TRASH` point it
    /// elsewhere for tests.
    public static func system(environment: [String: String] = ProcessInfo.processInfo.environment) -> Layout {
        var home = FileManager.default.homeDirectoryForCurrentUser
        // The account's home from the user database, so a stray $HOME can't point at the wrong folder.
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        func path(_ key: String, default value: URL) -> URL {
            guard let override = environment[key], !override.isEmpty else { return value }
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let (toolHome, newHome) = homes(in: home)
        var app = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
        if !FileManager.default.fileExists(atPath: app.path),
           let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeApp.bundleID) {
            app = found
        }
        return Layout(
            liveData: path("CMA_CLAUDE_DIR", default: home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)),
            home: path("CMA_HOME", default: toolHome),
            claudeApp: app,
            trash: environment["CMA_TRASH"].map { URL(fileURLWithPath: $0, isDirectory: true) },
            newHome: environment["CMA_HOME", default: ""].isEmpty ? newHome : nil)
    }

    /// This tool's folder in a user's home, `~/.claude-multi-accounts`. Versions before 3 kept it
    /// in `~/.claude-desktop-swap`, which stays in use until it has moved; a link is left there then.
    static func homes(in userHome: URL) -> (home: URL, newHome: URL?) {
        let current = userHome.appendingPathComponent(".claude-multi-accounts", isDirectory: true)
        let old = userHome.appendingPathComponent(".claude-desktop-swap", isDirectory: true)
        if !Files.exists(current) && Files.isRealDirectory(old) { return (old, current) }
        return (current, nil)
    }
}

public enum ClaudeApp {
    public static let bundleID = "com.anthropic.claudefordesktop"
    /// The main executable inside Claude.app; its helper processes have other names.
    static let executableSuffix = "/Claude.app/Contents/MacOS/Claude"
    /// Claude's updater (Squirrel's ShipIt). Other apps bring their own copy, so the path tells
    /// Claude's apart; it stays the same while the update moves Claude.app aside.
    static let updaterSuffix = "/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt"
    static let userDataSwitch = "--user-data-dir="
}
