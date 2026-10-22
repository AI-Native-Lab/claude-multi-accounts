import Foundation
import SQLite3

/// Synthetic accounts for the demo and the README screenshots. Nothing here touches the real
/// Claude or its data: everything lives in a temporary folder, and Claude is never started.
public enum Demo {
    struct Person {
        var name: String
        var uuid: String
        var loginDays: Double
        var size: Int64
    }

    static let people = [
        Person(name: "Personal", uuid: "d3m0a001-0000-4000-8000-000000000001", loginDays: 27, size: 41_000_000),
        Person(name: "Work · Northwind", uuid: "d3m0a002-0000-4000-8000-000000000002", loginDays: 22, size: 1_380_000_000),
        Person(name: "Client · Acme Studio", uuid: "d3m0a003-0000-4000-8000-000000000003", loginDays: 9, size: 36_000_000),
        Person(name: "Research", uuid: "d3m0a004-0000-4000-8000-000000000004", loginDays: -4, size: 512_000_000),
    ]
    /// Accounts the demo "signs in to" when it opens Claude signed out.
    static let newcomers = ["Side project", "Team trial", "Teaching"]

    /// Where the demo keeps its pretend Claude data and accounts.
    public static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeMultiAccountsDemo", isDirectory: true)
    }

    /// Builds a fresh pretend Mac with four synthetic accounts and returns a manager working on it:
    /// "Personal" in the main Claude, "Work · Northwind" open in its own window, "Client · Acme
    /// Studio" saved, and "Research" saved with an expired sign-in.
    public static func makeManager() throws -> AccountManager {
        let fm = FileManager.default
        let root = Self.root
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        let layout = Layout(liveData: root.appendingPathComponent("Claude", isDirectory: true),
                            home: root.appendingPathComponent("swap-home", isDirectory: true),
                            claudeApp: root.appendingPathComponent("Claude.app", isDirectory: true),
                            trash: root.appendingPathComponent("Trash", isDirectory: true))
        try fm.createDirectory(at: layout.claudeApp, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.liveData, withIntermediateDirectories: true)
        try Login.writeJSON(["locale": "en-US"], to: layout.liveData.appendingPathComponent("config.json"))

        let claude = SimulatedClaude(liveData: layout.liveData)
        claude.quitDelay = 0.8
        var arrivals = 0
        claude.signIn = { folder in
            // Plays someone signing in a moment after Claude opens signed out.
            let name = newcomers[arrivals % newcomers.count]
            arrivals += 1
            let uuid = "d3m0b\(String(format: "%03d", arrivals))-0000-4000-8000-0000000000\(String(format: "%02d", arrivals))"
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                try? signIn(folder, uuid: uuid, marker: name, days: 30)
            }
        }

        let manager = AccountManager(layout: layout, claude: claude)
        manager.settleDelay = 0
        manager.log = { _ in }
        let sizes = Dictionary(uniqueKeysWithValues: people.map { ($0.uuid, $0.size) })
        manager.sizeProvider = { folder in
            Login.accountUUID(in: folder).flatMap { sizes[$0] } ?? 24_000_000
        }

        // Every account signed in once in the main Claude and was saved when it switched away.
        var accounts: [Account] = []
        for (index, person) in people.enumerated() {
            let folder = layout.accountsRoot.appendingPathComponent(person.uuid, isDirectory: true)
            try signIn(folder, uuid: person.uuid, marker: person.name, days: person.loginDays, asAccountFolder: true)
            let saved = Date().addingTimeInterval(-Double(index * 2 + 1) * 86_400)
            accounts.append(Account(uuid: person.uuid, name: person.name, savedAt: Registry.timestamp.string(from: saved)))
        }
        try manager.saveAccounts(accounts)

        // "Personal" is in the main Claude; "Work · Northwind" is open in its own window.
        try Login.copy(from: manager.layout.folder(of: accounts[0]), to: layout.liveData)
        try claude.launchMain(app: layout.claudeApp)
        try manager.openWindow(accounts[1].uuid)
        return manager
    }

    /// Writes a synthetic sign-in into a data folder: a Cookies database with a claude.ai session
    /// cookie and the three config keys, holding placeholder text instead of real values.
    static func signIn(_ folder: URL, uuid: String, marker: String, days: Double, asAccountFolder: Bool = false) throws {
        try Files.privateFolder(folder)
        let cookies = folder.appendingPathComponent("Cookies")
        try? FileManager.default.removeItem(at: cookies)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(cookies.path, &db) == SQLITE_OK else { throw SwapError.io("Can't create \(cookies.path)") }
        let expires = Int64((Date().timeIntervalSince1970 + days * 86_400 + Login.chromeEpochOffset) * 1_000_000)
        let sql = """
            CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER, has_expires INTEGER);
            INSERT INTO cookies VALUES ('.claude.ai', 'sessionKey', '', x'763130', \(expires), 1);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SwapError.io("Can't write \(cookies.path)") }
        let keys: [String: Any] = [
            "oauth:tokenCache": "demo placeholder for \(marker)",
            "oauth:tokenCacheV2": "demo placeholder for \(marker)",
            "lastKnownAccountUuid": uuid,
        ]
        let config = folder.appendingPathComponent("config.json")
        if !asAccountFolder || Files.exists(config) {
            var object = (try? Login.readJSON(config)) ?? [:]
            object.merge(keys) { _, new in new }
            try Login.writeJSON(object, to: config)
        } else {
            try Login.writeJSON(keys, to: folder.appendingPathComponent("auth.json"))
        }
    }
}
