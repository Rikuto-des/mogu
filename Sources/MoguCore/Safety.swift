import Foundation
import Darwin

public enum SafetyError: LocalizedError {
    case rejected(String)
    public var errorDescription: String? { if case .rejected(let reason) = self { return reason }; return nil }
}

public struct FileStamp: Codable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public let size: Int64
    public let modified: Int64
    public let modifiedNanos: Int64
    public let changed: Int64
    public let changedNanos: Int64
    public let mode: UInt16
    public let links: UInt16
    public static func read(_ url: URL) throws -> FileStamp {
        var s = stat()
        guard lstat(url.path, &s) == 0 else { throw SafetyError.rejected("ファイルを確認できません。再スキャンしてください。") }
        return from(s)
    }
    public static func from(_ s: stat) -> FileStamp { FileStamp(device: s.st_dev, inode: s.st_ino, size: s.st_size, modified: Int64(s.st_mtimespec.tv_sec), modifiedNanos: Int64(s.st_mtimespec.tv_nsec), changed: Int64(s.st_ctimespec.tv_sec), changedNanos: Int64(s.st_ctimespec.tv_nsec), mode: s.st_mode, links: s.st_nlink) }
    public func sameContent(as other: FileStamp) -> Bool { device == other.device && inode == other.inode && size == other.size && modified == other.modified && modifiedNanos == other.modifiedNanos && mode == other.mode && links == other.links }
    public var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    public var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
}

public struct RootIdentity: Codable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public init(url: URL) throws {
        let s = try FileStamp.read(url)
        guard s.isDirectory else { throw SafetyError.rejected("通常のフォルダを選んでください。リンクは対象にできません。") }
        device = s.device; inode = s.inode
    }
}

public enum Safety {
    public static let protectedComponents: Set<String> = [".git", ".svn", ".ssh", ".gnupg", ".Trash", ".Trashes", "Backups.backupdb", "MobileSync", "Keychains", "Archives", "Backups", ".Mogu-Staging", "node_modules"]
    public static let protectedExtensions: Set<String> = ["app", "framework", "bundle", "xcarchive", "photoslibrary", "photolibrary", "musiclibrary", "p12", "pfx", "pem", "key", "mobileprovision", "provisionprofile", "keychain-db", "swift", "m", "h", "c", "cpp", "py", "js", "ts", "gd", "cs", "blend", "psd", "sqlite", "sqlite3", "db"]
    public static func validateRoot(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == path else { throw SafetyError.rejected("リンクを経由した場所は対象にできません。元のフォルダを選んでください。") }
        guard path != "/", !["/System", "/usr", "/bin", "/sbin", "/Library", "/Applications", "/private"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw SafetyError.rejected("この場所はシステムが管理しています。ホーム内のフォルダを選んでください。")
        }
        guard !isProtected(url) else { throw SafetyError.rejected("バックアップ・履歴・重要なデータは保護しています。別のフォルダを選んでください。") }
        _ = try RootIdentity(url: url)
    }
    public static func isProtected(_ url: URL) -> Bool {
        url.pathComponents.contains(where: { $0.hasPrefix(".Mogu-Staging") || protectedComponents.contains($0) || protectedExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) })
    }
    public static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let u = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return u != r && u.hasPrefix(r + "/")
    }
}

public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
