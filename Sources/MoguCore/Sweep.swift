import Foundation
import Darwin

public enum SweepLevel: String, Codable { case safe, review }
public enum RemovalMode: String, Codable { case trash, delete }

/// A folder or file that can be removed as a whole, with a human explanation of what it is.
public struct SweepItem: Identifiable {
    public let id: String
    public let url: URL
    public let title: String
    /// Items of the same kind are shown together under this heading.
    public let group: String
    public let note: String
    public let level: SweepLevel
    /// Bundle IDs of apps that use this item. A trailing "." matches every ID with that prefix.
    public let owners: [String]
    public let ownerName: String?
    public let stamp: FileStamp
    public var bytes: Int64
    public init(url: URL, title: String, group: String? = nil, note: String, level: SweepLevel, owners: [String] = [], ownerName: String? = nil, stamp: FileStamp, bytes: Int64 = 0) {
        id = url.path; self.url = url; self.title = title; self.group = group ?? title; self.note = note; self.level = level
        self.owners = owners; self.ownerName = ownerName; self.stamp = stamp; self.bytes = bytes
    }
    /// The name to use outside of its group, e.g. "Codexの会話履歴 · 2026年6月".
    public var displayName: String { group == title ? title : "\(group) · \(title)" }
    public func ownerIsRunning(_ running: Set<String>) -> Bool {
        owners.contains { owner in running.contains { $0 == owner || (owner.hasSuffix(".") && $0.hasPrefix(owner)) } }
    }
}

public struct SweepScanResult {
    public var items: [SweepItem] = []
    public var skipped = 0
    public var cancelled = false
}

public enum Sweep {
    /// Smaller items are not worth listing. Tests lower these.
    public static var minimumBytes: Int64 = 20_000_000
    public static var downloadMinimumBytes: Int64 = 50_000_000

    struct Proposal {
        var url: URL; var title: String; var group: String; var note: String; var level: SweepLevel
        var owners: [String] = []; var ownerName: String? = nil
        var minimumBytes: Int64 = Sweep.minimumBytes
        /// Build output folders are only offered when Git confirms they are not source.
        var buildOutput = false
    }

    // MARK: Scan

    /// Finds known regenerable folders and files that need review, then measures them.
    /// `found` is called from worker threads as each item is measured.
    public static func scan(home: URL, cancellation: Cancellation, now: Date = Date(), found: (SweepItem) -> Void = { _ in }) -> SweepScanResult {
        let proposals = discover(home: home, now: now)
        var result = SweepScanResult()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: proposals.count) { index in
            guard !cancellation.isCancelled else { return }
            guard let item = evaluate(proposals[index], cancellation: cancellation) else { lock.lock(); result.skipped += 1; lock.unlock(); return }
            lock.lock(); result.items.append(item); lock.unlock()
            found(item)
        }
        result.cancelled = cancellation.isCancelled
        result.items.sort { $0.bytes > $1.bytes }
        return result
    }

    static func evaluate(_ proposal: Proposal, cancellation: Cancellation) -> SweepItem? {
        var proposal = proposal
        guard let stamp = try? FileStamp.read(proposal.url), stamp.isDirectory || stamp.isRegular else { return nil }
        if proposal.buildOutput {
            switch Git.state(of: proposal.url) {
            case .tracked: return nil
            case .untracked: break
            case .unknown:
                proposal.level = .review
                proposal.note = "ビルド成果物らしいフォルダですが、Gitで確認できませんでした。中身を確認してください。"
            }
        }
        let bytes = allocatedSize(proposal.url, cancellation: cancellation)
        guard !cancellation.isCancelled, bytes >= proposal.minimumBytes else { return nil }
        return SweepItem(url: proposal.url, title: proposal.title, group: proposal.group, note: proposal.note, level: proposal.level, owners: proposal.owners, ownerName: proposal.ownerName, stamp: stamp, bytes: bytes)
    }

    static func discover(home: URL, now: Date) -> [Proposal] {
        var proposals = fixedLocations(home: home)
        proposals += cacheFolders(home: home)
        proposals += codexHistory(home: home, now: now)
        proposals += claudeHistory(home: home, now: now)
        proposals += projectArtifacts(home: home)
        proposals += downloads(home: home)
        // Never offer the same place twice, or a folder together with something inside it.
        var unique: [Proposal] = []
        for proposal in proposals.sorted(by: { $0.url.path.count < $1.url.path.count }) {
            let path = proposal.url.standardizedFileURL.path
            if unique.contains(where: { let p = $0.url.standardizedFileURL.path; return p == path || path.hasPrefix(p + "/") }) { continue }
            unique.append(proposal)
        }
        return unique
    }

    struct Rule {
        let path: String, group: String, title: String, note: String, level: SweepLevel
        var owners: [String] = [], ownerName: String? = nil
    }
    static let fixedRules: [Rule] = [
        Rule(path: "Library/Developer/Xcode/DerivedData", group: "Xcode・シミュレータ", title: "Xcodeのビルド中間データ", note: "Xcodeが作る中間ファイルです。消しても次のビルドが少し遅くなるだけです。", level: .safe, owners: ["com.apple.dt.Xcode"], ownerName: "Xcode"),
        Rule(path: "Library/Developer/Xcode/iOS DeviceSupport", group: "Xcode・シミュレータ", title: "iPhone実機のデバッグ用データ", note: "実機をつないだときに作られる記号情報です。次に実機をつなぐと作り直されます。", level: .safe, owners: ["com.apple.dt.Xcode"], ownerName: "Xcode"),
        Rule(path: "Library/Developer/CoreSimulator/Caches", group: "Xcode・シミュレータ", title: "シミュレータのキャッシュ", note: "iOSシミュレータの起動用キャッシュです。次の起動時に作り直されます。", level: .safe, owners: ["com.apple.iphonesimulator"], ownerName: "Simulator"),
        Rule(path: "Library/Developer/Xcode/Archives", group: "Xcode・シミュレータ", title: "Xcodeのアーカイブ", note: "提出したビルドの控えです。過去のバージョンのクラッシュ解析に使うことがあります。", level: .review, owners: ["com.apple.dt.Xcode"], ownerName: "Xcode"),
        Rule(path: ".npm/_cacache", group: "開発ツールのキャッシュ", title: "npmのダウンロードキャッシュ", note: "npm installで取得したパッケージの控えです。次のインストール時に再ダウンロードされます。", level: .safe),
        Rule(path: ".npm/_npx", group: "開発ツールのキャッシュ", title: "npxのツールキャッシュ", note: "npxで一度使ったツールのコピーです。次に使うとき再ダウンロードされます。", level: .safe),
        Rule(path: ".yarn/berry/cache", group: "開発ツールのキャッシュ", title: "yarnのキャッシュ", note: "yarnでダウンロードしたパッケージの控えです。次のyarn installで再取得されます。", level: .safe),
        Rule(path: "Library/pnpm/store", group: "開発ツールのキャッシュ", title: "pnpmのストア", note: "pnpmのパッケージ置き場です。次のpnpm installで再取得されます。", level: .safe),
        Rule(path: ".bun/install/cache", group: "開発ツールのキャッシュ", title: "bunのキャッシュ", note: "bunでダウンロードしたパッケージの控えです。次のインストールで再取得されます。", level: .safe),
        Rule(path: ".cache/uv", group: "開発ツールのキャッシュ", title: "uv（Python）のキャッシュ", note: "uvで取得したPythonパッケージの控えです。必要なときに再取得されます。", level: .safe),
        Rule(path: ".cache/pip", group: "開発ツールのキャッシュ", title: "pipのキャッシュ", note: "pipで取得したパッケージの控えです。必要なときに再取得されます。", level: .safe),
        Rule(path: ".gradle/caches", group: "開発ツールのキャッシュ", title: "Gradleのキャッシュ", note: "Android/Javaビルドの依存ファイルです。次のビルドで再取得されます。", level: .safe),
        Rule(path: ".cargo/registry/cache", group: "開発ツールのキャッシュ", title: "Rustクレートの控え", note: "cargoでダウンロードしたクレートの圧縮ファイルです。必要なときに再取得されます。", level: .safe),
        Rule(path: ".cache/codex-runtimes/codex-primary-runtime", group: "Codex", title: "Codexの実行環境", note: "Codexが使うNode.jsなどです。会話は消えません。次にCodexを起動すると再ダウンロードされます。", level: .safe, owners: ["com.openai.codex"], ownerName: "Codex"),
        Rule(path: ".cache/huggingface", group: "AIモデル", title: "ダウンロード済みのAIモデル", note: "Hugging Faceから取得したモデルです。消すと次に使うとき再ダウンロードに時間がかかります。", level: .review),
        Rule(path: "Library/Application Support/Claude/vm_bundles", group: "Claude", title: "Claudeアプリの仮想環境", note: "Claudeアプリが作業用に使う仮想マシンです。会話は消えません。次に使うとき数GBを再ダウンロードします。", level: .review, owners: ["com.anthropic.claudefordesktop"], ownerName: "Claude"),
        Rule(path: ".codex/generated_images", group: "Codex", title: "Codexで生成した画像", note: "Codexが作った画像の保存先です。残したい画像は先に別の場所へ保存してください。", level: .review, owners: ["com.openai.codex"], ownerName: "Codex"),
        Rule(path: ".codex/archived_sessions", group: "Codex", title: "Codexのアーカイブ済み会話", note: "アーカイブした会話の記録です。消すと読み返せません。", level: .review, owners: ["com.openai.codex"], ownerName: "Codex"),
    ]

    static func fixedLocations(home: URL) -> [Proposal] {
        var result = fixedRules.map { rule in
            Proposal(url: home.appendingPathComponent(rule.path), title: rule.title, group: rule.group, note: rule.note, level: rule.level, owners: rule.owners, ownerName: rule.ownerName)
        }
        let runtimes = home.appendingPathComponent(".cache/codex-runtimes")
        for child in children(of: runtimes) where child.lastPathComponent.hasPrefix("codex-runtime-install-") {
            result.append(Proposal(url: child, title: "Codexのインストール一時ファイル", group: "Codex", note: "Codexの実行環境を入れたときに残った一時ファイルです。消しても影響はありません。", level: .safe, owners: ["com.openai.codex"], ownerName: "Codex"))
        }
        return result
    }

    struct CacheNote { let title: String, note: String; var owners: [String] = []; var ownerName: String? = nil }
    static let cacheNotes: [String: CacheNote] = [
        "Adobe": CacheNote(title: "Adobeアプリのキャッシュ", note: "After Effectsのプレビューやようこそ画面の画像などです。次に使うとき作り直されます。", owners: ["com.adobe."], ownerName: "Adobeアプリ"),
        "Google": CacheNote(title: "Chromeのキャッシュ", note: "閲覧したページの画像などです。ログイン状態・履歴・ブックマークは消えません。", owners: ["com.google.Chrome"], ownerName: "Chrome"),
        "com.openai.codex": CacheNote(title: "Codexのアップデートの残り", note: "Codexアプリのアップデート用にダウンロードされたファイルです。会話は消えません。", owners: ["com.openai.codex"], ownerName: "Codex"),
        "Codex": CacheNote(title: "Codexアプリの表示キャッシュ", note: "アプリ内の画面表示用キャッシュです。会話は消えません。初回表示が少し遅くなるだけです。", owners: ["com.openai.codex"], ownerName: "Codex"),
        "Homebrew": CacheNote(title: "Homebrewのダウンロード", note: "brewで取得したインストール用ファイルです。インストール済みのアプリには影響しません。"),
        "pip": CacheNote(title: "pipのキャッシュ", note: "pipで取得したパッケージの控えです。必要なときに再取得されます。"),
        "node-gyp": CacheNote(title: "node-gypのヘッダー", note: "ネイティブモジュールのビルド用ファイルです。必要なときに再取得されます。"),
        "org.swift.swiftpm": CacheNote(title: "Swift Packageのキャッシュ", note: "SwiftPMで取得したパッケージの控えです。次のビルドで再取得されます。"),
        "CocoaPods": CacheNote(title: "CocoaPodsのキャッシュ", note: "pod installで取得したライブラリの控えです。次のインストールで再取得されます。"),
        "Yarn": CacheNote(title: "yarnのキャッシュ", note: "yarnでダウンロードしたパッケージの控えです。次のyarn installで再取得されます。"),
        "ms-playwright": CacheNote(title: "Playwrightのブラウザ", note: "テスト用ブラウザです。npx playwright installで入れ直せます。"),
        "JetBrains": CacheNote(title: "JetBrains IDEのキャッシュ", note: "IDEのインデックスなどです。次に開くとき作り直されます（少し時間がかかります）。", owners: ["com.jetbrains."], ownerName: "JetBrains IDE"),
        "Firefox": CacheNote(title: "Firefoxのキャッシュ", note: "閲覧したページの画像などです。ログイン状態や履歴は消えません。", owners: ["org.mozilla.firefox"], ownerName: "Firefox"),
        "Microsoft Edge": CacheNote(title: "Edgeのキャッシュ", note: "閲覧したページの画像などです。ログイン状態や履歴は消えません。", owners: ["com.microsoft.edgemac"], ownerName: "Edge"),
        "BraveSoftware": CacheNote(title: "Braveのキャッシュ", note: "閲覧したページの画像などです。ログイン状態や履歴は消えません。", owners: ["com.brave.Browser"], ownerName: "Brave"),
    ]

    static func cacheFolders(home: URL) -> [Proposal] {
        children(of: home.appendingPathComponent("Library/Caches")).compactMap { child in
            let name = child.lastPathComponent
            // Apple's own caches are managed by the system and are often in use.
            guard !name.hasPrefix("com.apple."), !name.hasPrefix(".") else { return nil }
            var info = cacheNotes[name]
            if info == nil, name.hasPrefix("com.adobe.") { info = cacheNotes["Adobe"] }
            if info == nil, name.hasSuffix(".ShipIt") {
                info = CacheNote(title: "アップデートの一時ファイル", note: "\(name.replacingOccurrences(of: ".ShipIt", with: ""))の自動アップデートで残ったファイルです。")
            }
            let looksLikeBundleID = name.split(separator: ".").count >= 3
            let fallback = CacheNote(title: "\(name)のキャッシュ", note: "アプリが必要に応じて作り直すキャッシュです。アプリを終了してから消してください。", owners: looksLikeBundleID ? [name] : [], ownerName: looksLikeBundleID ? name : nil)
            let note = info ?? fallback
            return Proposal(url: child, title: note.title, group: "アプリのキャッシュ", note: note.note, level: .safe, owners: note.owners, ownerName: note.ownerName)
        }
    }

    /// Codex keeps sessions under sessions/YYYY/MM. The current and previous month are left alone.
    static func codexHistory(home: URL, now: Date) -> [Proposal] {
        let calendar = Calendar(identifier: .gregorian)
        let current = calendar.dateComponents([.year, .month], from: now)
        let currentIndex = (current.year ?? 0) * 12 + (current.month ?? 1) - 1
        var result: [Proposal] = []
        for year in children(of: home.appendingPathComponent(".codex/sessions")) {
            guard let y = Int(year.lastPathComponent) else { continue }
            for month in children(of: year) {
                guard let m = Int(month.lastPathComponent), (1...12).contains(m), currentIndex - (y * 12 + m - 1) >= 2 else { continue }
                result.append(Proposal(url: month, title: "\(y)年\(m)月", group: "Codexの会話履歴", note: "この月のCodexの会話記録です。消すとこの月の会話を再開・検索できなくなります。", level: .review, owners: ["com.openai.codex"], ownerName: "Codex"))
            }
        }
        return result
    }

    /// Claude Code transcripts per project. Only projects untouched for two weeks are offered.
    static func claudeHistory(home: URL, now: Date) -> [Proposal] {
        let prefix = home.path.replacingOccurrences(of: "/", with: "-") + "-"
        return children(of: home.appendingPathComponent(".claude/projects")).compactMap { project in
            let newest = children(of: project).compactMap { try? FileStamp.read($0).modified }.max() ?? 0
            guard now.timeIntervalSince1970 - Double(newest) > 14 * 86_400 else { return nil }
            var name = project.lastPathComponent
            if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
            return Proposal(url: project, title: name, group: "Claude Codeの会話履歴", note: "2週間以上使っていないプロジェクトの会話記録です。消すとこの会話を再開できなくなります。", level: .review)
        }
    }

    static let developmentRoots = ["Developer", "Projects", "projects", "dev", "src", "code", "repos", "GitHub", "workspace"]

    /// Walks project folders and offers dependency and build output folders.
    static func projectArtifacts(home: URL, maxDepth: Int = 6, maxDirectories: Int = 60_000) -> [Proposal] {
        var result: [Proposal] = []
        var seenRoots: Set<String> = []
        var visited = 0
        for name in developmentRoots {
            let root = home.appendingPathComponent(name)
            guard let stamp = try? FileStamp.read(root), stamp.isDirectory, seenRoots.insert("\(stamp.device):\(stamp.inode)").inserted else { continue }
            var stack: [(URL, Int)] = [(root, 0)]
            while let (directory, depth) = stack.popLast(), visited < maxDirectories {
                visited += 1
                let entries = children(of: directory)
                let names = Set(entries.map(\.lastPathComponent))
                for child in entries {
                    guard let stamp = try? FileStamp.read(child), stamp.isDirectory else { continue }
                    if var proposal = artifact(child, siblings: names) {
                        // Name each one after where it lives, e.g. "koikoi/web/node_modules".
                        proposal.title = String(child.path.dropFirst(root.path.count + 1))
                        result.append(proposal); continue
                    }
                    let childName = child.lastPathComponent
                    if childName.hasPrefix(".") || isPackage(childName) { continue }
                    if depth + 1 < maxDepth { stack.append((child, depth + 1)) }
                }
            }
        }
        return result
    }

    static func artifact(_ url: URL, siblings: Set<String>) -> Proposal? {
        let name = url.lastPathComponent
        func safe(_ kind: String, _ note: String) -> Proposal { Proposal(url: url, title: name, group: kind, note: note, level: .safe) }
        let unity = siblings.contains("Assets") && siblings.contains("ProjectSettings")
        switch name {
        case "node_modules":
            return safe("npmパッケージ（node_modules）", "このプロジェクトの依存パッケージです。npm install（またはyarn / pnpm）で元に戻せます。")
        case ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular", ".expo":
            return safe("フレームワークのビルドキャッシュ", "開発サーバーやビルドが作るキャッシュです。次のビルドで作り直されます。")
        case "DerivedData":
            return safe("Xcodeのビルド中間データ", "このプロジェクト用のXcode中間ファイルです。次のビルドで作り直されます。")
        case "Pods" where siblings.contains("Podfile"):
            return safe("CocoaPodsのライブラリ", "pod installで元に戻せます。")
        case ".build" where siblings.contains("Package.swift"):
            return safe("Swift Packageのビルド成果物", "swift buildで作り直せます。")
        case "target" where siblings.contains("Cargo.toml"):
            return safe("Rustのビルド成果物", "cargo buildで作り直せます。")
        case ".gradle" where siblings.contains("settings.gradle") || siblings.contains("settings.gradle.kts") || siblings.contains("build.gradle"):
            return safe("Gradleのプロジェクトキャッシュ", "次のビルドで作り直されます。")
        case ".godot" where siblings.contains("project.godot"):
            return safe("Godotのインポートキャッシュ", "次にGodotで開くと作り直されます（少し時間がかかります）。")
        case "Library" where unity, "Temp" where unity, "obj" where unity:
            return safe("Unityのキャッシュ", "Unityが作るキャッシュです。次に開くと作り直されます（大きいプロジェクトは時間がかかります）。")
        case ".venv", "venv":
            let python = ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock"].contains(where: siblings.contains)
            return Proposal(url: url, title: name, group: "Pythonの仮想環境", note: python ? "依存ファイルから作り直せます（pip install -r requirements.txt など）。" : "Pythonの仮想環境です。作り直し方が分かる場合だけ消してください。", level: python ? .safe : .review)
        case "build", "Build", "Builds":
            var proposal = safe("ビルド成果物", "Gitで管理されていないビルド出力です。再ビルドすれば作り直せます。")
            proposal.buildOutput = true
            return proposal
        case "dist":
            return Proposal(url: url, title: name, group: "配布用ビルド（dist）", note: "ビルドの出力先です。公開済みのファイルを保存している場合は残してください。", level: .review)
        default:
            return nil
        }
    }

    static func downloads(home: URL) -> [Proposal] {
        let folder = home.appendingPathComponent("Downloads")
        let entries = children(of: folder)
        let names = Set(entries.map(\.lastPathComponent))
        return entries.compactMap { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            let ext = url.pathExtension.lowercased()
            let base = url.deletingPathExtension().lastPathComponent
            let note: String
            if ["dmg", "pkg", "iso"].contains(ext) { note = "インストーラーです。インストール済みなら不要です。" }
            else if ["zip", "tar", "gz", "tgz", "7z", "rar", "xz"].contains(ext) {
                note = names.contains(base) ? "同じ名前の展開済みフォルダがあります。中身が同じなら不要です。" : "圧縮ファイルです。展開済み・使用済みなら不要です。"
            } else if (try? FileStamp.read(url))?.isDirectory == true { note = "ダウンロードしたフォルダです。使い終わっていれば不要です。" }
            else { note = "ダウンロードしたファイルです。必要かどうか確認してください。" }
            return Proposal(url: url, title: name, group: "ダウンロード", note: note, level: .review, minimumBytes: downloadMinimumBytes)
        }
    }

    static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
    }
    static func isPackage(_ name: String) -> Bool {
        ["app", "xcodeproj", "xcworkspace", "xcarchive", "framework", "bundle", "photoslibrary", "musiclibrary"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    /// Disk space used by a file or folder. Never follows symbolic links; hard links count once.
    public static func allocatedSize(_ url: URL, cancellation: Cancellation = Cancellation()) -> Int64 {
        guard let path = strdup(url.path) else { return 0 }
        defer { free(path) }
        var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }
        var total: Int64 = 0, count = 0
        var linked: Set<UInt64> = []
        while let entry = fts_read(fts) {
            count += 1
            if count % 4096 == 0, cancellation.isCancelled { return total }
            let info = Int32(entry.pointee.fts_info)
            guard info == FTS_F || info == FTS_SL || info == FTS_DEFAULT || info == FTS_DP, let s = entry.pointee.fts_statp else { continue }
            if info == FTS_F, s.pointee.st_nlink > 1, !linked.insert(s.pointee.st_ino).inserted { continue }
            total += Int64(s.pointee.st_blocks) * 512
        }
        return total
    }

    // MARK: Removal

    public static func protectedTargets(home: URL) -> Set<String> {
        Set(["", "Library", "Library/Caches", "Library/Application Support", "Library/Developer", "Developer", "Downloads", "Documents", "Desktop", ".codex", ".codex/sessions", ".claude", ".claude/projects", ".cache", ".npm"].map {
            ($0.isEmpty ? home : home.appendingPathComponent($0)).standardizedFileURL.path
        })
    }

    /// Re-checks an item right before it is removed.
    public static func validate(_ item: SweepItem, home: URL, runningApps: Set<String>) throws -> FileStamp {
        let path = item.url.standardizedFileURL.path
        guard Safety.isDescendant(item.url, of: home), !protectedTargets(home: home).contains(path) else { throw SafetyError.rejected("この場所は整理の対象にできません。") }
        guard item.url.resolvingSymlinksInPath().standardizedFileURL.path == path else { throw SafetyError.rejected("リンクを経由した場所は対象にできません。") }
        guard !item.url.pathComponents.contains(where: { [".git", ".ssh", ".gnupg", "Keychains", ".Trash"].contains($0) }) else { throw SafetyError.rejected("保護している場所です。") }
        let now = try FileStamp.read(item.url)
        guard now.device == item.stamp.device, now.inode == item.stamp.inode, now.isDirectory == item.stamp.isDirectory, now.isDirectory || now.isRegular else {
            throw SafetyError.rejected("調べたあとに入れ替わりました。もう一度調べてください。")
        }
        if now.isDirectory {
            var git = stat()
            guard lstat(item.url.appendingPathComponent(".git").path, &git) != 0 else { throw SafetyError.rejected("Gitリポジトリのため対象にできません。") }
        }
        if (try? item.url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true { throw SafetyError.rejected("iCloud上の項目は対象にできません。") }
        if item.ownerIsRunning(runningApps) { throw SafetyError.rejected("\(item.ownerName ?? "関連アプリ")が起動中です。終了してからもう一度実行してください。") }
        return now
    }

    public static func remove(_ items: [SweepItem], mode: RemovalMode, home: URL, store: HistoryStore, cancellation: Cancellation,
                              runningApps: () -> Set<String>,
                              trash: Cleanup.TrashOperation = Cleanup.systemTrash,
                              delete: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                              progress: (Int, Int64) -> Void = { _, _ in }) -> CleanupResult {
        var result = CleanupResult()
        var entries: [HistoryEntry]
        do { entries = try store.load() } catch { result.failures = ["履歴を読み込めないため、何も変更していません。\(error.localizedDescription)"]; return result }
        let homeIdentity = try? RootIdentity(url: home)
        var seen: Set<String> = []
        for item in items {
            if cancellation.isCancelled { result.stopped = true; break }
            guard seen.insert(item.id).inserted else { continue }
            do {
                let stamp = try validate(item, home: home, runningApps: runningApps())
                var entry = HistoryEntry(original: item.url, root: home, stamp: stamp, rootIdentity: homeIdentity)
                entries.append(entry)
                try store.save(entries) // Never change a user file without a saved record first.
                switch mode {
                case .trash:
                    entry.trashURL = try trash(item.url)
                    entry.state = .moved; entry.message = "ゴミ箱へ移しました。ゴミ箱を空にすると容量が空きます。"
                case .delete:
                    do { try delete(item.url) } catch {
                        let partial = (try? FileStamp.read(item.url)) != nil
                        throw SafetyError.rejected(partial ? "一部を削除できませんでした。\(error.localizedDescription)" : error.localizedDescription)
                    }
                    entry.state = .deleted; entry.message = "完全に削除しました。元に戻せません。"
                }
                entries[entries.count - 1] = entry
                result.moved.append(item.id); result.bytes += item.bytes
                do { try store.save(entries) } catch {
                    result.failures.append("処理は完了しましたが、履歴を更新できませんでした。")
                    result.stopped = true; progress(result.moved.count, result.bytes); break
                }
                progress(result.moved.count, result.bytes)
            } catch {
                if let index = entries.lastIndex(where: { $0.original == item.url && $0.state == .planned }) {
                    entries[index].state = .failed; entries[index].message = error.localizedDescription
                } else {
                    var skipped = HistoryEntry(original: item.url, root: home, stamp: item.stamp, rootIdentity: homeIdentity)
                    skipped.state = .failed; skipped.message = error.localizedDescription
                    entries.append(skipped)
                }
                do { try store.save(entries) } catch { result.stopped = true }
                result.failures.append("\(item.displayName): \(error.localizedDescription)")
                if result.stopped { break }
            }
        }
        return result
    }
}

enum Git {
    enum State { case tracked, untracked, unknown }
    /// Whether Git tracks anything inside `url`. Folders outside a repository are `unknown`.
    static func state(of url: URL) -> State {
        let parent = url.deletingLastPathComponent()
        var probe = parent, inRepo = false
        while probe.path != "/" && !probe.path.isEmpty {
            var s = stat()
            if lstat(probe.appendingPathComponent(".git").path, &s) == 0 { inRepo = true; break }
            probe.deleteLastPathComponent()
        }
        // /usr/bin/git is a shim that asks to install developer tools when they are missing.
        let tools = ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        guard inRepo, tools.contains(where: FileManager.default.isExecutableFile(atPath:)) else { return .unknown }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", parent.path, "ls-files", "-z", "--", url.lastPathComponent]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unknown }
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else { return .unknown }
        return output.isEmpty ? .untracked : .tracked
    }
}
