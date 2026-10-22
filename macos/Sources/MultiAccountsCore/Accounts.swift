import Foundation

/// A Claude account this tool knows. Its sign-in is kept in its own folder (see `Layout`).
public struct Account: Codable, Equatable, Identifiable, Sendable {
    public var uuid: String
    public var name: String
    /// When its sign-in was last saved, in local time ("2026-10-21T09:30:00").
    public var savedAt: String?
    /// The folder's name under `accounts/` when it isn't the uuid: an account first signed in to
    /// in its own window keeps the folder that window was started on.
    public var folder: String?

    public var id: String { uuid }

    public init(uuid: String, name: String, savedAt: String? = nil, folder: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.savedAt = savedAt
        self.folder = folder
    }

    public var savedDate: Date? { savedAt.flatMap(Registry.timestamp.date(from:)) }
}

/// `accounts.json`: the names and order of the accounts.
struct Registry: Codable {
    var version = 1
    var accounts: [Account]

    static func load(_ url: URL) throws -> [Account] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(Registry.self, from: Data(contentsOf: url)).accounts
    }

    static func save(_ accounts: [Account], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try Files.writeAtomically(encoder.encode(Registry(accounts: accounts)), to: url)
    }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func now() -> String { timestamp.string(from: Date()) }
}

extension Array where Element == Account {
    /// "Account 3", or the next free number.
    func defaultName() -> String {
        let taken = Set(map { $0.name.lowercased() })
        var n = count + 1
        while taken.contains("account \(n)") { n += 1 }
        return "Account \(n)"
    }

    /// Finds an account by list number, name (ignoring case), uuid or a uuid prefix of 4+ characters.
    func find(_ query: String) throws -> Account {
        if let number = Int(query), (1...count).contains(number) { return self[number - 1] }
        if let match = first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame || $0.uuid == query }) {
            return match
        }
        let prefixed = filter { query.count >= 4 && $0.uuid.hasPrefix(query) }
        if prefixed.count == 1 { return prefixed[0] }
        let names = enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: ", ")
        throw SwapError.noSuchAccount(query, saved: names.isEmpty ? "none" : names)
    }
}

enum Files {
    /// Writes a file atomically, readable only by its owner.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw SwapError.io("Can't write \(tmp.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(tmp.path, url.path) == 0 else {
            throw SwapError.io("Can't replace \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Creates a folder (and its parents) readable only by its owner.
    @discardableResult
    static func privateFolder(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A folder itself, not a link to one.
    static func isRealDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory
    }
}
