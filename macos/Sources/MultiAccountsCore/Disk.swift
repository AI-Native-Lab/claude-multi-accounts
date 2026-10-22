import Foundation

public enum Disk {
    /// The space a folder takes on disk, the figure `du` shows. Symbolic links aren't followed.
    public static func allocatedSize(of folder: URL) -> Int64? {
        // du exits non-zero when a running Claude removes a file mid-scan; the total is still right.
        guard let output = try? run("/usr/bin/du", ["-sk", folder.path], allowFailure: true),
              let field = output.split(separator: "\t").first,
              let kilobytes = Int64(field.trimmingCharacters(in: .whitespaces)) else { return nil }
        return kilobytes * 1024
    }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
