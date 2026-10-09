import Foundation
import Darwin

public struct HistoryEntry: Codable, Identifiable {
    public enum State: String, Codable { case planned, moved, deleted, failed, restored }
    public let id: UUID
    public let date: Date
    public let original: URL
    public let root: URL
    public let stamp: FileStamp
    public let rootIdentity: RootIdentity?
    public var trashURL: URL?
    public var trashBookmark: Data?
    public var state: State
    public var message: String
    public init(original: URL, root: URL, stamp: FileStamp, rootIdentity: RootIdentity?) {
        id = UUID(); date = Date(); self.original = original; self.root = root; self.stamp = stamp; self.rootIdentity = rootIdentity
        state = .planned; message = "処理前。中断された場合は元の場所とゴミ箱を確認してください。"
    }
}

public final class HistoryStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: url))
    }
    public func save(_ entries: [HistoryEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

public struct CleanupResult {
    public var moved: [String] = []
    public var failures: [String] = []
    public var bytes: Int64 = 0
    public var stopped = false
}

public enum Cleanup {
    public typealias TrashOperation = (URL) throws -> URL?
    public static func systemTrash(_ url: URL) throws -> URL? {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL?
    }
    public static func restore(_ entry: HistoryEntry, source: URL, store: HistoryStore) throws {
        guard entry.state == .moved else { throw SafetyError.rejected("この項目は復元できる状態ではありません。") }
        try Safety.validateRoot(entry.root)
        if let identity = entry.rootIdentity, try RootIdentity(url: entry.root) != identity { throw SafetyError.rejected("元のフォルダが変更されたため、復元を中止しました。") }
        guard Safety.isDescendant(entry.original, of: entry.root) else { throw SafetyError.rejected("元の場所を確認できません。") }
        guard source.resolvingSymlinksInPath().path == source.standardizedFileURL.path else { throw SafetyError.rejected("リンクは復元できません。") }
        let sourceStamp = try FileStamp.read(source)
        guard sourceStamp.isRegular || sourceStamp.isDirectory, sourceStamp.sameContent(as: entry.stamp) else { throw SafetyError.rejected("元のファイルと一致しない、または内容が変更されています。Finderで内容を確認してください。") }
        var parent = entry.original.deletingLastPathComponent()
        while parent.path != entry.root.path {
            guard try FileStamp.read(parent).isDirectory else { throw SafetyError.rejected("元のフォルダを確認できません。") }
            parent.deleteLastPathComponent()
        }
        // lstat also catches dangling symlinks. Never replace anything at the original location.
        var existing = stat()
        guard lstat(entry.original.path, &existing) != 0, errno == ENOENT else { throw SafetyError.rejected("元の場所に同名のファイルがあります。上書きせずに中止しました。") }
        var entries = try store.load()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { throw SafetyError.rejected("履歴が見つかりません。") }
        try FileManager.default.moveItem(at: source, to: entry.original)
        entries[index].state = .restored; entries[index].message = "元の場所へ戻しました。"
        try store.save(entries)
    }
}
