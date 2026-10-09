import XCTest
@testable import MoguCore

final class SafetyTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default
    override func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent("build/test-runs/" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        Sweep.minimumBytes = 1; Sweep.downloadMinimumBytes = 1
    }
    override func tearDownWithError() throws { if let root { try fm.removeItem(at: root) } }
    @discardableResult
    func file(_ relative: String, size: Int = 20) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: size).write(to: url)
        return url
    }
    func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    var store: HistoryStore { HistoryStore(url: root.appendingPathComponent("journal/history.json")) }
    let october = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 9).date!
    func scan() -> [SweepItem] { Sweep.scan(home: root, cancellation: Cancellation(), now: october).items }
    func item(_ relative: String, in items: [SweepItem]) -> SweepItem? { items.first { $0.url.path == root.appendingPathComponent(relative).path } }
    func moveToFixtureTrash(_ url: URL) throws -> URL? {
        let dest = root.appendingPathComponent("FixtureTrash/" + url.lastPathComponent)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: dest); return dest
    }
    func git(_ directory: URL, _ arguments: String...) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", directory.path] + arguments
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
    }

    func testFindsKnownLocationsWithLevelsAndNotes() throws {
        try file("Library/Caches/Google/Chrome/Default/Cache/data")
        try file("Library/Caches/com.apple.Safari/data")
        try file("Developer/web/package.json"); try file("Developer/web/node_modules/a/index.js")
        _ = try folder("Developer/game/Assets"); _ = try folder("Developer/game/ProjectSettings"); try file("Developer/game/Library/cache.bin")
        try file("Developer/notunity/Library/notes.txt")
        try file("Developer/tool/.venv/lib/a.py")
        try file(".codex/sessions/2026/06/a.jsonl"); try file(".codex/sessions/2026/09/b.jsonl")
        try file("Downloads/setup.dmg"); try file("Downloads/Stems.zip"); _ = try folder("Downloads/Stems"); try file("Downloads/Stems/a.wav")
        let items = scan()
        XCTAssertEqual(item("Library/Caches/Google", in: items)?.level, .safe)
        XCTAssertEqual(item("Library/Caches/Google", in: items)?.title, "Chromeのキャッシュ")
        XCTAssertNil(item("Library/Caches/com.apple.Safari", in: items))
        XCTAssertEqual(item("Developer/web/node_modules", in: items)?.level, .safe)
        XCTAssertEqual(item("Developer/game/Library", in: items)?.level, .safe)
        XCTAssertNil(item("Developer/notunity/Library", in: items))
        XCTAssertEqual(item("Developer/tool/.venv", in: items)?.level, .review, "No dependency file: cannot be recreated automatically")
        XCTAssertEqual(item(".codex/sessions/2026/06", in: items)?.level, .review)
        XCTAssertNil(item(".codex/sessions/2026/09", in: items), "Recent conversations are never offered")
        XCTAssertEqual(item("Downloads/setup.dmg", in: items)?.level, .review)
        XCTAssertTrue(item("Downloads/Stems.zip", in: items)?.note.contains("展開済み") == true)
        XCTAssertTrue(items.allSatisfy { !$0.note.isEmpty })
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Developer/web/node_modules/a/index.js").path), "Scanning never changes files")
    }

    func testChosenProjectRoots() throws {
        try file("Developer/web/package.json"); try file("Developer/web/node_modules/a/index.js")
        try file("Desktop/apps/site/package.json"); try file("Desktop/apps/site/node_modules/a/index.js")
        let defaults = Sweep.scan(home: root, cancellation: Cancellation(), now: october).items
        XCTAssertNotNil(item("Developer/web/node_modules", in: defaults))
        XCTAssertNil(item("Desktop/apps/site/node_modules", in: defaults), "Only the usual project folders by default")
        let apps = root.appendingPathComponent("Desktop/apps")
        let chosen = Sweep.scan(home: root, projectRoots: [apps], cancellation: Cancellation(), now: october).items
        XCTAssertEqual(item("Desktop/apps/site/node_modules", in: chosen)?.title, "site/node_modules")
        XCTAssertNil(item("Developer/web/node_modules", in: chosen), "Usual folders that were switched off are not searched")
        XCTAssertEqual(Sweep.defaultProjectRoots(home: root).map(\.lastPathComponent), ["Developer"])
    }

    func testProjectRootMustBeInsideHomeAndOutsideLibrary() throws {
        XCTAssertNoThrow(try Sweep.validateProjectRoot(try folder("Desktop/apps"), home: root))
        XCTAssertThrowsError(try Sweep.validateProjectRoot(root, home: root), "The whole home folder is too broad")
        XCTAssertThrowsError(try Sweep.validateProjectRoot(try folder("Library/Application Support/Thing"), home: root))
        XCTAssertThrowsError(try Sweep.validateProjectRoot(try folder("Library"), home: root))
        XCTAssertThrowsError(try Sweep.validateProjectRoot(try folder("Developer/web/node_modules"), home: root))
        let elsewhere = try folder("elsewhere")
        XCTAssertThrowsError(try Sweep.validateProjectRoot(elsewhere, home: root.appendingPathComponent("Desktop")))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try Sweep.validateProjectRoot(root.appendingPathComponent("Linked"), home: root))
        XCTAssertThrowsError(try Sweep.validateProjectRoot(root.appendingPathComponent("Missing"), home: root))
        XCTAssertThrowsError(try Sweep.validateProjectRoot(try folder(".nvm/versions/node"), home: root), "Hidden tool folders are not project folders")
    }

    func testRepositoryAtHomeDoesNotMakeBuildFoldersSafe() throws {
        guard ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].contains(where: fm.isExecutableFile(atPath:)) else { throw XCTSkip("git is not installed") }
        try git(root, "init", "-q")
        try file("Documents/work/Build/report.pdf")
        let items = Sweep.scan(home: root, projectRoots: [root.appendingPathComponent("Documents")], cancellation: Cancellation(), now: october).items
        XCTAssertEqual(item("Documents/work/Build", in: items)?.level, .review, "A dotfiles repository at home says nothing about other folders")
    }

    func testNestedItemsAreNotOfferedTwice() throws {
        try file("Developer/app/package.json")
        try file("Developer/app/node_modules/pkg/node_modules/inner/a.js")
        let items = scan()
        XCTAssertNotNil(item("Developer/app/node_modules", in: items))
        XCTAssertNil(item("Developer/app/node_modules/pkg/node_modules", in: items))
    }

    func testBuildFoldersDependOnGit() throws {
        guard ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].contains(where: fm.isExecutableFile(atPath:)) else { throw XCTSkip("git is not installed") }
        let repo = try folder("Developer/repo")
        try git(repo, "init", "-q")
        try file("Developer/repo/build/output.bin")
        try file("Developer/repo/tools/build/script.sh")
        try git(repo, "add", "tools/build/script.sh")
        try file("Developer/loose/build/output.bin")
        let items = scan()
        XCTAssertEqual(item("Developer/repo/build", in: items)?.level, .safe)
        XCTAssertNil(item("Developer/repo/tools/build", in: items), "Tracked source folders named build are never offered")
        XCTAssertEqual(item("Developer/loose/build", in: items)?.level, .review, "Without Git the folder needs review")
    }

    func testRepositoryConfigCannotRunCommands() throws {
        guard ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].contains(where: fm.isExecutableFile(atPath:)) else { throw XCTSkip("git is not installed") }
        let repo = try folder("Developer/evil")
        try git(repo, "init", "-q")
        let marker = root.appendingPathComponent("ran")
        let hook = try file("hook.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try git(repo, "config", "core.fsmonitor", hook.path)
        try file("Developer/evil/build/output.bin")
        _ = scan()
        XCTAssertFalse(fm.fileExists(atPath: marker.path), "A repository's own config must never run commands during a scan")
    }

    func testTrashAndDeleteModesRecordHistory() throws {
        try file("Library/Caches/AppA/a.bin"); try file("Library/Caches/AppB/b.bin")
        let items = scan()
        let a = try XCTUnwrap(item("Library/Caches/AppA", in: items)), b = try XCTUnwrap(item("Library/Caches/AppB", in: items))
        var deleted: [URL] = []
        let trashed = Sweep.remove([a], mode: .trash, home: root, store: store, cancellation: Cancellation(), runningApps: { [] }, trash: moveToFixtureTrash)
        let removed = Sweep.remove([b], mode: .delete, home: root, store: store, cancellation: Cancellation(), runningApps: { [] }, trash: { _ in XCTFail("delete mode must not trash"); return nil }, delete: { deleted.append($0); try FileManager.default.removeItem(at: $0) })
        XCTAssertEqual(trashed.moved, [a.id]); XCTAssertEqual(removed.moved, [b.id]); XCTAssertEqual(deleted, [b.url])
        XCTAssertFalse(fm.fileExists(atPath: a.url.path)); XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("FixtureTrash/AppA/a.bin").path))
        XCTAssertFalse(fm.fileExists(atPath: b.url.path))
        XCTAssertEqual(try store.load().map(\.state), [.moved, .deleted])
    }

    func testSwappedFolderIsNotRemoved() throws {
        try file("Library/Caches/AppA/a.bin")
        let a = try XCTUnwrap(item("Library/Caches/AppA", in: scan()))
        try fm.removeItem(at: a.url); try file("Library/Caches/AppA/other.bin")
        let r = Sweep.remove([a], mode: .delete, home: root, store: store, cancellation: Cancellation(), runningApps: { [] })
        XCTAssertTrue(r.moved.isEmpty); XCTAssertEqual(r.failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Library/Caches/AppA/other.bin").path))
        XCTAssertEqual(try store.load().map(\.state), [.failed])
    }

    func testLinksRepositoriesAndProtectedPlacesAreRejected() throws {
        let outside = try folder("outside"); try file("outside/keep.txt")
        _ = try folder("Library/Caches")
        try fm.createSymbolicLink(at: root.appendingPathComponent("Library/Caches/Linked"), withDestinationURL: outside)
        XCTAssertNil(item("Library/Caches/Linked", in: scan()))
        // A folder that later becomes a link is caught right before removal.
        try file("Library/Caches/AppA/a.bin")
        let a = try XCTUnwrap(item("Library/Caches/AppA", in: scan()))
        XCTAssertThrowsError(try Sweep.validate(SweepItem(url: root.appendingPathComponent("Library/Caches/Linked/keep.txt"), title: "", note: "", level: .safe, stamp: a.stamp), home: root, runningApps: []))
        try file("Library/Caches/AppA/.git/HEAD")
        XCTAssertThrowsError(try Sweep.validate(a, home: root, runningApps: []))
        let caches = SweepItem(url: root.appendingPathComponent("Library/Caches"), title: "", note: "", level: .safe, stamp: try FileStamp.read(root.appendingPathComponent("Library/Caches")))
        XCTAssertThrowsError(try Sweep.validate(caches, home: root, runningApps: []))
        let outsideItem = SweepItem(url: outside, title: "", note: "", level: .safe, stamp: try FileStamp.read(outside))
        XCTAssertThrowsError(try Sweep.validate(outsideItem, home: root.appendingPathComponent("Library"), runningApps: []))
        XCTAssertTrue(fm.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
    }

    func testRunningOwnerIsSkipped() throws {
        try file("Library/Caches/Adobe/a.bin")
        let adobe = try XCTUnwrap(item("Library/Caches/Adobe", in: scan()))
        XCTAssertTrue(adobe.ownerIsRunning(["com.adobe.Photoshop"]))
        XCTAssertFalse(adobe.ownerIsRunning(["com.adobexyz.App"]))
        let r = Sweep.remove([adobe], mode: .delete, home: root, store: store, cancellation: Cancellation(), runningApps: { ["com.adobe.AfterEffects"] })
        XCTAssertTrue(r.moved.isEmpty); XCTAssertTrue(fm.fileExists(atPath: adobe.url.path))
    }

    func testCancellationAndCorruptedHistoryPreventChanges() throws {
        try file("Library/Caches/AppA/a.bin")
        let a = try XCTUnwrap(item("Library/Caches/AppA", in: scan()))
        let token = Cancellation(); token.cancel()
        XCTAssertTrue(Sweep.remove([a], mode: .delete, home: root, store: store, cancellation: token, runningApps: { [] }).stopped)
        try file("journal/history.json")
        let r = Sweep.remove([a], mode: .delete, home: root, store: store, cancellation: Cancellation(), runningApps: { [] })
        XCTAssertFalse(r.failures.isEmpty); XCTAssertTrue(fm.fileExists(atPath: a.url.path))
    }

    func testRestoreFolderAndNeverOverwrite() throws {
        try file("Library/Caches/AppA/a.bin", size: 20)
        let a = try XCTUnwrap(item("Library/Caches/AppA", in: scan()))
        _ = Sweep.remove([a], mode: .trash, home: root, store: store, cancellation: Cancellation(), runningApps: { [] }, trash: moveToFixtureTrash)
        let entry = try XCTUnwrap(store.load().first)
        let source = try XCTUnwrap(entry.trashURL)
        try file("Library/Caches/AppA/new.bin", size: 7)
        XCTAssertThrowsError(try Cleanup.restore(entry, source: source, store: store))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Library/Caches/AppA/new.bin").path))
        try fm.removeItem(at: a.url)
        try Cleanup.restore(entry, source: source, store: store)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Library/Caches/AppA/a.bin")).count, 20)
        XCTAssertEqual(try store.load().first?.state, .restored)
        let other = try folder("FixtureTrash/Other")
        XCTAssertThrowsError(try Cleanup.restore(entry, source: other, store: store))
    }

    func testAllocatedSizeDoesNotFollowLinksAndCountsHardLinksOnce() throws {
        let big = try file("outside/big.bin", size: 1_000_000)
        let dir = try folder("measure")
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: big.deletingLastPathComponent())
        try file("measure/a.bin", size: 100_000)
        try fm.linkItem(at: root.appendingPathComponent("measure/a.bin"), to: dir.appendingPathComponent("a-hard.bin"))
        let size = Sweep.allocatedSize(dir)
        XCTAssertGreaterThanOrEqual(size, 100_000); XCTAssertLessThan(size, 400_000)
    }

    func testProtectedRootsAndPathPrefixBoundary() throws {
        XCTAssertThrowsError(try Safety.validateRoot(URL(fileURLWithPath: "/")))
        XCTAssertThrowsError(try Safety.validateRoot(URL(fileURLWithPath: "/System")))
        XCTAssertFalse(Safety.isDescendant(URL(fileURLWithPath: root.path+"-other/a.zip"), of: root))
    }
}
