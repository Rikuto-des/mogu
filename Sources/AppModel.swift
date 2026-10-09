import AppKit
import Darwin

struct SweepGroup { let name: String; let items: [SweepItem]; let bytes: Int64; let sharedNote: String? }

final class AppModel {
    enum Phase { case idle, scanning, ready, confirming, working, done }
    var phase = Phase.idle
    var items: [SweepItem] = []
    var selected = Set<String>()
    var tab = SweepLevel.safe
    var observers: [() -> Void] = []
    var status = "Macの中から、消していいものを探します。"
    var progress: Double = 0
    var movedBytes: Int64 = 0
    var operationBytes: Int64 = 0
    var operationCount = 0
    var doneCount = 0
    var result = CleanupResult()
    var lastMode = RemovalMode.trash
    var lastScan: Date?
    /// A background scan that keeps the current list until the newer one is ready.
    var refreshing = false
    var refreshToken = Cancellation()
    var refreshScheduler: NSBackgroundActivityScheduler?
    var cancellation = Cancellation()
    let worker = DispatchQueue(label: "jp.rikuto.mogu.files", qos: .userInitiated)
    let dataDirectory: URL
    let history: HistoryStore
    var historyWindow: NSWindow?
    var locationsWindow: NSWindow?
    var isBusy: Bool { phase == .scanning || phase == .working }
    let homeOverride: URL?
    var userHome: URL {
        if let homeOverride { return homeOverride }
        if let path = getpwuid(getuid())?.pointee.pw_dir { return URL(fileURLWithPath: String(cString: path), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    var mode: RemovalMode {
        get { RemovalMode(rawValue: UserDefaults.standard.string(forKey: "removalMode") ?? "") ?? .trash }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "removalMode"); notify() }
    }
    /// Advanced: usual project folders the user switched off (by name), and folders they added.
    var skippedProjectRoots: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "skippedProjectRoots") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "skippedProjectRoots"); locationsChanged() }
    }
    var addedProjectRoots: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: "addedProjectRoots") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "addedProjectRoots"); locationsChanged() }
    }
    /// Added folders are checked again on every scan, since they may have moved or become links.
    var projectRoots: [URL] {
        let home = userHome
        let usual = Sweep.defaultProjectRoots(home: home).filter { !skippedProjectRoots.contains($0.lastPathComponent) }
        return usual + addedProjectRoots.filter { (try? Sweep.validateProjectRoot($0, home: home)) != nil }
    }
    func addProjectRoot(_ url: URL) throws {
        try Sweep.validateProjectRoot(url, home: userHome)
        let path = url.standardizedFileURL.path
        guard !addedProjectRoots.contains(where: { $0.standardizedFileURL.path == path }) else { return }
        addedProjectRoots.append(url.standardizedFileURL)
    }
    /// The list is out of date once the places change, so it is refreshed in the background.
    func locationsChanged() { lastScan = nil; notify(); refresh() }
    var runningApps: Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
    var selectedItems: [SweepItem] { items.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var freeBytes: Int64? { (try? userHome.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage }
    func items(_ level: SweepLevel) -> [SweepItem] { items.filter { $0.level == level } }
    func bytes(_ level: SweepLevel) -> Int64 { items(level).reduce(0) { $0 + $1.bytes } }

    init(homeDirectory: URL? = nil) {
        homeOverride = homeDirectory
        dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mogu", isDirectory: true)
        history = HistoryStore(url: dataDirectory.appendingPathComponent("history.json"))
    }
    func notify() { observers.forEach { $0() } }
    func alert(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "閉じる")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }

    /// Called whenever the menu opens. Scanning happens in the background, so the list is normally ready.
    func prepare() {
        guard !isBusy else { return }
        if phase == .done || phase == .confirming { phase = .ready }
        if phase == .idle { scan() } else { notify(); if lastScan == nil { refresh() } }
    }
    /// Checks again every half hour while Mogu runs, at a time that suits the system.
    func startBackgroundRefresh() {
        let scheduler = NSBackgroundActivityScheduler(identifier: (Bundle.main.bundleIdentifier ?? "jp.rikuto.mogu") + ".refresh")
        scheduler.repeats = true; scheduler.interval = 30 * 60; scheduler.tolerance = 5 * 60; scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            DispatchQueue.main.async {
                // Never swap the list while the user is looking at it.
                let open = (NSApp.delegate as? AppDelegate)?.popover.isShown == true
                if let self, !open, self.lastScan.map({ Date().timeIntervalSince($0) > 20 * 60 }) ?? true { self.refresh() }
                completion(.finished)
            }
        }
        refreshScheduler = scheduler
    }
    func refresh() {
        guard phase == .ready, !refreshing else { return }
        refreshing = true; refreshToken = Cancellation(); notify()
        let token = refreshToken, home = userHome, running = runningApps, roots = projectRoots
        worker.async(qos: .utility, flags: .enforceQoS) {
            let result = Sweep.scan(home: home, projectRoots: roots, cancellation: token)
            DispatchQueue.main.async {
                guard self.refreshToken === token else { return }
                self.refreshing = false
                // Something else started (removal, a full scan); try again later.
                guard !result.cancelled, self.phase == .ready else { self.lastScan = nil; self.notify(); return }
                // Keep the user's choices for items that are still there; new items get the usual default.
                let before = Dictionary(self.items.map { ($0.id, self.selected.contains($0.id)) }, uniquingKeysWith: { a, _ in a })
                self.items = result.items
                self.selected = Set(result.items.filter { before[$0.id] ?? ($0.level == .safe && !$0.ownerIsRunning(running)) }.map(\.id))
                self.lastScan = self.projectRoots == roots ? Date() : nil
                self.status = self.items.isEmpty ? "消していいものは見つかりませんでした。" : ""
                self.notify()
                if self.lastScan == nil { self.refresh() }
            }
        }
    }
    /// The cancelled refresh finishes quietly; its result is dropped.
    func cancelRefresh() { if refreshing { refreshToken.cancel(); refreshToken = Cancellation(); refreshing = false } }
    func scan() {
        guard !isBusy else { return }
        cancelRefresh()
        items = []; selected = []; progress = 0; phase = .scanning; cancellation = Cancellation()
        status = "調べています…"; notify()
        let token = cancellation, home = userHome, running = runningApps, roots = projectRoots
        worker.async {
            let result = Sweep.scan(home: home, projectRoots: roots, cancellation: token) { item in
                DispatchQueue.main.async {
                    guard self.cancellation === token, !self.items.contains(where: { $0.id == item.id }) else { return }
                    self.items.append(item); self.items.sort { $0.bytes > $1.bytes }
                    if item.level == .safe && !item.ownerIsRunning(running) { self.selected.insert(item.id) }
                    self.notify()
                }
            }
            DispatchQueue.main.async {
                guard self.cancellation === token else { return }
                self.items = result.items
                self.selected = self.selected.intersection(result.items.map(\.id))
                // If the places changed during the scan, scan them again right away.
                self.phase = .ready; self.lastScan = self.projectRoots == roots ? Date() : nil
                self.status = result.cancelled ? "途中で止めました。見つかった分だけ表示しています。" : self.items.isEmpty ? "消していいものは見つかりませんでした。" : ""
                self.notify()
                if self.lastScan == nil, !result.cancelled { self.refresh() }
            }
        }
    }
    func stop() { cancellation.cancel(); notify() }

    func toggle(_ item: SweepItem) {
        guard phase == .ready else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
        notify()
    }
    func toggleGroup(_ ids: [String]) {
        guard phase == .ready else { return }
        if ids.allSatisfy(selected.contains) { selected.subtract(ids) } else { selected.formUnion(ids) }
        notify()
    }
    func groups(_ level: SweepLevel) -> [SweepGroup] {
        Dictionary(grouping: items(level), by: \.group).map { name, list in
            SweepGroup(name: name, items: list.sorted { $0.bytes > $1.bytes }, bytes: list.reduce(0) { $0 + $1.bytes },
                       sharedNote: Set(list.map(\.note)).count == 1 ? list[0].note : nil)
        }.sorted { $0.bytes > $1.bytes }
    }
    func toggleAll(_ level: SweepLevel) {
        guard phase == .ready || phase == .scanning else { return }
        let ids = items(level).map(\.id)
        if ids.allSatisfy(selected.contains) { selected.subtract(ids) } else { selected.formUnion(ids) }
        notify()
    }
    func beginConfirm() {
        guard phase == .ready, !selected.isEmpty else { return }
        phase = .confirming; notify()
    }
    func cancelConfirm() {
        guard phase == .confirming else { return }
        phase = .ready; notify()
    }
    func perform() {
        guard phase == .confirming else { return }
        let list = selectedItems, mode = self.mode, home = userHome
        guard !list.isEmpty else { phase = .ready; notify(); return }
        cancelRefresh()
        phase = .working; lastMode = mode; progress = 0; movedBytes = 0; doneCount = 0
        operationBytes = list.reduce(0) { $0 + $1.bytes }; operationCount = list.count; cancellation = Cancellation()
        notify()
        let token = cancellation
        worker.async {
            let result = Sweep.remove(list, mode: mode, home: home, store: self.history, cancellation: token, runningApps: {
                var ids: Set<String> = []; DispatchQueue.main.sync { ids = self.runningApps }; return ids
            }, progress: { count, bytes in
                DispatchQueue.main.async { self.doneCount = count; self.movedBytes = bytes; self.progress = Double(bytes) / Double(max(1, self.operationBytes)); self.notify() }
            })
            DispatchQueue.main.async {
                self.result = result; self.movedBytes = result.bytes; self.doneCount = result.moved.count
                self.progress = Double(result.bytes) / Double(max(1, self.operationBytes))
                let done = Set(result.moved)
                self.items.removeAll { done.contains($0.id) }; self.selected.subtract(done)
                self.phase = .done; self.notify()
            }
        }
    }
    func finish() {
        guard phase == .done else { return }
        phase = .ready; progress = 0; notify()
    }
    func reveal(_ item: SweepItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func openTrash() { NSWorkspace.shared.open(userHome.appendingPathComponent(".Trash")) }

    func showHistory() {
        guard !isBusy else { return }
        (NSApp.delegate as? AppDelegate)?.popover.performClose(nil)
        let controller = HistoryController(model: self)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 580), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Mogu — 整理の履歴"; w.contentViewController = controller; w.isReleasedWhenClosed = false
        historyWindow?.close(); historyWindow = w; w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showLocations() {
        (NSApp.delegate as? AppDelegate)?.popover.performClose(nil)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Mogu — 調べる場所"; w.contentViewController = LocationsController(model: self); w.isReleasedWhenClosed = false
        locationsWindow?.close(); locationsWindow = w; w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func restore(_ entry: HistoryEntry) {
        guard !isBusy else { return }
        guard let source = entry.trashURL else { alert("元に戻せません", "ゴミ箱の中の場所が記録されていません。Finderでゴミ箱を開き、項目を右クリックして「戻す」を選んでください。"); return }
        let a = NSAlert(); a.messageText = "元の場所へ戻しますか？"; a.informativeText = "\(entry.original.path)\n\n同じ名前のものがある場合は上書きしません。"
        a.addButton(withTitle: "戻す"); a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Cleanup.restore(entry, source: source, store: history)
            lastScan = nil; phase = phase == .done ? .ready : phase; notify(); refresh(); showHistory()
        } catch { alert("元に戻せませんでした", error.localizedDescription + "\n\nゴミ箱を空にしたものは戻せません。ゴミ箱に残っている場合は、Finderで項目を右クリックして「戻す」を選んでください。") }
    }
}

func formatBytes(_ value: Int64) -> String {
    let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: value)
}
