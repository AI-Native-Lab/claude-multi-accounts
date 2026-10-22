import Foundation
import SQLite3

/// The sign-in inside a Claude data folder, and copying it between folders.
///
/// Claude keeps its sign-in in two places in its data folder:
///
///     Cookies      the claude.ai web session (the sessionKey cookies)
///     config.json  oauth:tokenCache, oauth:tokenCacheV2 and lastKnownAccountUuid
///                  (the tokens the Code tab runs on, and which account it is)
///
/// Both are encrypted with the app's "Claude Safe Storage" key from the Keychain, which is the
/// same for every account and every data folder on this Mac, so a sign-in works wherever it is
/// put. Nothing here decrypts or reads those values: only cookie names, hosts and expiry dates.
///
/// An account folder that has never been opened in its own window holds the cookie files and
/// `auth.json` (the three config keys). Once opened, it is a full Claude data folder whose
/// `config.json` holds the keys instead.
enum Login {
    static let configKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]
    static let uuidKey = "lastKnownAccountUuid"
    static let cookieFiles = ["Cookies", "Cookies-journal", "Cookies-wal", "Cookies-shm"]
    static let sessionCookies = ["sessionKey", "sessionKeyV2", "sessionKeyV3"]
    static let hosts = ["claude.ai", ".claude.ai"]
    /// Plain settings copied into a new window's folder so it looks like the main Claude.
    static let sharedSettings = ["locale", "userThemeMode"]
    /// Seconds from 1601-01-01 (Chrome's epoch) to 1970-01-01.
    static let chromeEpochOffset: Double = 11_644_473_600

    // MARK: - Reading

    /// When the claude.ai sign-in cookie in a data folder expires. Nil means there is no valid
    /// one (signed out or expired); `.distantFuture` means it lasts until Claude quits.
    static func expiry(in folder: URL) -> Date? {
        let cookies = folder.appendingPathComponent("Cookies")
        guard Files.exists(cookies) else { return nil }
        let uri = "file:\(cookies.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cookies.path)?mode=ro&immutable=1"
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        let sql = "SELECT expires_utc, has_expires FROM cookies"
            + " WHERE host_key IN (\(hosts.map { _ in "?" }.joined(separator: ",")))"
            + " AND name IN (\(sessionCookies.map { _ in "?" }.joined(separator: ",")))"
            + " AND (length(encrypted_value) > 0 OR length(value) > 0)"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in (hosts + sessionCookies).enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var best: Date?
        while sqlite3_step(statement) == SQLITE_ROW {
            let expires = sqlite3_column_int64(statement, 0)
            let hasExpires = sqlite3_column_int64(statement, 1) != 0
            let date = hasExpires
                ? Date(timeIntervalSince1970: Double(expires) / 1_000_000 - chromeEpochOffset)
                : .distantFuture
            if date > Date(), best.map({ date > $0 }) ?? true { best = date }
        }
        return best
    }

    /// The sign-in keys of a data folder: from `config.json`, or `auth.json` in an account
    /// folder that has never been opened in its own window. Nil when there are none.
    static func keys(in folder: URL) -> [String: Any]? {
        for name in ["config.json", "auth.json"] {
            let url = folder.appendingPathComponent(name)
            guard Files.exists(url), let object = try? readJSON(url) else { continue }
            let keys = object.filter { configKeys.contains($0.key) }
            return keys.isEmpty ? nil : keys
        }
        return nil
    }

    /// The account a data folder's sign-in belongs to, as Claude recorded it.
    static func accountUUID(in folder: URL) -> String? {
        keys(in: folder)?[uuidKey] as? String
    }

    static func hasSignIn(in folder: URL) -> Bool {
        keys(in: folder) != nil
    }

    // MARK: - Copying

    /// Makes `destination`'s sign-in a copy of `source`'s, leaving every other file and setting
    /// in `destination` alone. `source` nil signs `destination` out (on this Mac only).
    static func copy(from source: URL?, to destination: URL) throws {
        let keys = source.flatMap(Self.keys(in:)) ?? [:]
        if source != nil && keys.isEmpty {
            throw SwapError.io("\(source!.path) holds no sign-in.")
        }
        try Files.privateFolder(destination)

        // Remove every cookie sidecar first: a leftover journal from another account's database
        // would be replayed into the copied one.
        for name in cookieFiles {
            try? FileManager.default.removeItem(at: destination.appendingPathComponent(name))
        }
        if let source {
            for name in cookieFiles where Files.exists(source.appendingPathComponent(name)) {
                let tmp = destination.appendingPathComponent(".\(name).swap-tmp")
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: tmp)
                guard rename(tmp.path, destination.appendingPathComponent(name).path) == 0 else {
                    throw SwapError.io("Can't put \(name) in \(destination.path): \(String(cString: strerror(errno)))")
                }
            }
        }

        let config = destination.appendingPathComponent("config.json")
        if Files.exists(config) {
            var object = try readJSON(config)
            for key in configKeys { object[key] = nil }
            object.merge(keys) { _, new in new }
            try writeJSON(object, to: config)
            // Claude wipes a config.json it can't parse, so prove this one parses.
            _ = try readJSON(config)
            try? FileManager.default.removeItem(at: destination.appendingPathComponent("auth.json"))
        } else {
            try writeJSON(keys, to: destination.appendingPathComponent("auth.json"))
        }
    }

    /// Turns an account folder into a data folder Claude can open: its `auth.json` keys move into
    /// a `config.json`, together with the main Claude's language and theme.
    static func prepareForWindow(_ folder: URL, mainData: URL) throws {
        try Files.privateFolder(folder)
        let config = folder.appendingPathComponent("config.json")
        let auth = folder.appendingPathComponent("auth.json")
        guard !Files.exists(config) else { return }
        var object: [String: Any] = [:]
        if let main = try? readJSON(mainData.appendingPathComponent("config.json")) {
            object = main.filter { sharedSettings.contains($0.key) }
        }
        if Files.exists(auth) {
            object.merge(try readJSON(auth)) { _, new in new }
        }
        try writeJSON(object, to: config)
        try? FileManager.default.removeItem(at: auth)
    }

    // MARK: - JSON

    static func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwapError.io("\(url.path) isn't a JSON object.")
        }
        return object
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try Files.writeAtomically(data, to: url)
    }
}
