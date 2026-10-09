import AppKit

func actionButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded; b.font = .systemFont(ofSize: 12); return b
}
func wrapped(_ text: String, size: CGFloat = 12, lines: Int = 0) -> NSTextField {
    let l = label(text, size: size, color: Palette.secondary)
    l.maximumNumberOfLines = lines; l.lineBreakMode = .byWordWrapping; l.cell?.truncatesLastVisibleLine = true; return l
}
func place(_ parent: NSView, _ child: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    child.frame = NSRect(x: x, y: y, width: w, height: h); parent.addSubview(child)
}
func linkButton(_ title: String, target: AnyObject?, action: Selector, size: CGFloat = 11) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.isBordered = false; b.font = .systemFont(ofSize: size); b.contentTintColor = Palette.ink; return b
}

class PaperViewBase: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Palette.paper.setFill(); bounds.fill() }
}

/// A kind of data (e.g. node_modules) with its explanation shown once, and a total.
final class GroupRow: PaperViewBase {
    let group: SweepGroup
    unowned let model: AppModel
    let onExpand: () -> Void
    static func height(_ group: SweepGroup) -> CGFloat { group.sharedNote == nil ? 46 : 74 }
    init(group: SweepGroup, model: AppModel, expanded: Bool, running: Set<String>, width: CGFloat, onExpand: @escaping () -> Void) {
        self.group = group; self.model = model; self.onExpand = onExpand
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height(group)))
        let disclosure = linkButton(expanded ? "▾" : "▸", target: self, action: #selector(expand), size: 15)
        disclosure.contentTintColor = Palette.secondary; disclosure.setAccessibilityLabel(expanded ? "閉じる" : "中身を見る")
        place(self, disclosure, 0, 6, 20, 24)
        let ids = group.items.map(\.id)
        let chosen = ids.filter(model.selected.contains).count
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle))
        check.allowsMixedState = true
        check.state = chosen == 0 ? .off : chosen == ids.count ? .on : .mixed
        check.isEnabled = model.phase == .ready; check.contentTintColor = .black; check.setAccessibilityLabel(group.name + "をまとめて選択")
        place(self, check, 20, 8, 22, 22)
        place(self, label(group.name, size: 12.5, weight: .semibold), 46, 8, width-150, 19)
        let size = label(formatBytes(group.bytes), size: 12, mono: true); size.alignment = .right
        place(self, size, width-100, 8, 92, 19)
        let busy = group.items.filter { $0.ownerIsRunning(running) }.count
        var meta = "\(group.items.count)件"
        if group.items.count > 1 && chosen != ids.count { meta += " · \(chosen)件を選択" }
        if busy > 0 { meta += " · ⚠︎ 起動中のアプリのもの\(busy)件" }
        place(self, label(meta, size: 10, color: busy > 0 ? Palette.ink : Palette.secondary), 46, 27, width-54, 14)
        if let note = group.sharedNote { place(self, wrapped(note, size: 10.5, lines: 2), 46, 42, width-54, 30) }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func toggle() { model.toggleGroup(group.items.map(\.id)) }
    @objc func expand() { onExpand() }
    override func mouseDown(with event: NSEvent) { onExpand() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.line.setFill(); NSRect(x: 0, y: bounds.height-1, width: bounds.width, height: 1).fill()
    }
}

/// One folder or file inside a group.
final class ItemRow: PaperViewBase {
    let item: SweepItem
    unowned let model: AppModel
    /// Project items are named by their path, so the path line would only repeat it.
    static func showsPath(_ item: SweepItem, running: Bool) -> Bool { running || !item.url.path.hasSuffix("/" + item.title) }
    static func height(_ item: SweepItem, showsNote: Bool, running: Bool) -> CGFloat { (showsPath(item, running: running) ? 42 : 30) + (showsNote ? 30 : 0) }
    init(item: SweepItem, model: AppModel, showsNote: Bool, running: Bool, width: CGFloat) {
        self.item = item; self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height(item, showsNote: showsNote, running: running)))
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle))
        check.state = model.selected.contains(item.id) ? .on : .off
        check.isEnabled = model.phase == .ready
        check.contentTintColor = .black; check.setAccessibilityLabel(item.title + "を選択")
        place(self, check, 44, 5, 22, 22)
        let title = label(item.title, size: 12); title.lineBreakMode = .byTruncatingMiddle; title.toolTip = item.title
        place(self, title, 68, 5, width-170, 18)
        let size = label(formatBytes(item.bytes), size: 11.5, mono: true); size.alignment = .right; size.textColor = Palette.secondary
        place(self, size, width-100, 5, 92, 18)
        var y: CGFloat = 23
        if Self.showsPath(item, running: running) {
            let home = model.userHome.path
            let where_ = running ? "⚠︎ \(item.ownerName ?? "関連アプリ")が起動中。終了してから実行してください" : item.url.path.replacingOccurrences(of: home, with: "~")
            let path = label(where_, size: 9.5, color: running ? Palette.ink : Palette.secondary); path.lineBreakMode = .byTruncatingMiddle; path.toolTip = item.url.path
            place(self, path, 68, y, width-128, 14); y += 16
        }
        title.toolTip = item.url.path
        let compact = !Self.showsPath(item, running: running)
        let reveal = linkButton(compact ? "↗" : "Finder", target: self, action: #selector(show), size: compact ? 12 : 10)
        reveal.contentTintColor = Palette.secondary; reveal.setAccessibilityLabel(item.title + "をFinderで表示"); reveal.toolTip = "Finderで表示"
        if compact { size.frame.origin.x = width-124; title.frame.size.width = width-196; place(self, reveal, width-28, 4, 24, 20) }
        else { place(self, reveal, width-56, 20, 50, 18) }
        if showsNote { place(self, wrapped(item.note, size: 10.5, lines: 2), 68, y, width-76, 28) }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func toggle() { model.toggle(item) }
    @objc func show() { model.reveal(item) }
    override func mouseDown(with event: NSEvent) { model.toggle(item) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); bounds.fill()
        Palette.line.setFill(); NSRect(x: 44, y: bounds.height-1, width: bounds.width-44, height: 1).fill()
    }
}

final class PopoverController: NSViewController {
    let model: AppModel
    let heading = label("選んだ容量", size: 12, color: Palette.secondary)
    let value = label("—", size: 32, weight: .medium, mono: true)
    let subtitle = wrapped("", size: 11, lines: 2)
    let scene = PixelScene(frame: .zero)
    let tabs = NSSegmentedControl(labels: ["消していい", "確認が必要"], trackingMode: .selectOne, target: nil, action: nil)
    let count = label("", size: 11, color: Palette.secondary)
    let all = NSButton(title: "すべて選択", target: nil, action: nil)
    let scroll = NSScrollView()
    let panel = PaperViewBase(frame: .zero)
    let primary = PixelButton(frame: .zero)
    let back = NSButton(title: "戻る", target: nil, action: nil)
    let foot = label("", size: 10, color: Palette.secondary)
    var shownIDs: [String] = []
    var shownState = ""
    var shownLevel: SweepLevel?
    var expanded: Set<String> = []
    init(model: AppModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = PaperView(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
        place(view, label("MOGU", size: 17, weight: .heavy, mono: true), 26, 18, 100, 25)
        place(view, label("MAC CLEANER", size: 9, color: Palette.secondary, mono: true), 26, 43, 170, 16)
        let menu = NSButton(title: "•••", target: self, action: #selector(options(_:))); menu.isBordered = false; menu.setAccessibilityLabel("メニュー")
        place(view, menu, 340, 19, 36, 24)
        place(view, heading, 26, 66, 348, 18)
        place(view, value, 23, 82, 351, 40)
        place(view, scene, 12, 96, 376, 105)
        place(view, subtitle, 26, 192, 348, 30)
        tabs.target = self; tabs.action = #selector(tabChanged); tabs.selectedSegment = 0; tabs.selectedSegmentBezelColor = .black
        tabs.segmentDistribution = .fillEqually
        place(view, tabs, 26, 226, 348, 26)
        place(view, count, 30, 258, 270, 18)
        all.isBordered = false; all.font = .systemFont(ofSize: 11); all.target = self; all.action = #selector(toggleAll); all.alignment = .right
        place(view, all, 290, 256, 84, 20)
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        place(view, scroll, 14, 278, 372, 334)
        place(view, panel, 26, 226, 348, 386)
        primary.target = self; primary.action = #selector(primaryAction)
        place(view, primary, 26, 622, 348, 40)
        back.bezelStyle = .rounded; back.font = .systemFont(ofSize: 12); back.target = self; back.action = #selector(goBack)
        place(view, back, 22, 625, 96, 34)
        foot.alignment = .center
        place(view, foot, 26, 670, 348, 16)
        model.observers.append { [weak self] in self?.refresh() }; refresh()
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        model.cancelConfirm()
    }
    var showsList: Bool { model.phase == .idle || model.phase == .scanning || model.phase == .ready }

    func refresh() {
        guard isViewLoaded else { return }
        let phase = model.phase, mode = phase == .working || phase == .done ? model.lastMode : model.mode
        let selectedBytes = model.selectedBytes
        tabs.setLabel("消していい · \(formatBytes(model.bytes(.safe)))", forSegment: 0)
        tabs.setLabel("確認が必要 · \(formatBytes(model.bytes(.review)))", forSegment: 1)
        tabs.selectedSegment = model.tab == .safe ? 0 : 1
        for v in [tabs, count, all, scroll] as [NSView] { v.isHidden = !showsList }
        panel.isHidden = showsList
        if showsList { refreshList() } else { refreshPanel(mode: mode) }

        switch phase {
        case .working: heading.stringValue = mode == .trash ? "ゴミ箱へ移しています" : "削除しています"
        case .done: heading.stringValue = mode == .trash ? "ゴミ箱へ移した容量" : "削除した容量"
        default: heading.stringValue = model.selected.isEmpty ? "選んだ容量" : "選んだ容量 · \(model.selected.count)件"
        }
        value.stringValue = phase == .idle ? "—" : formatBytes(phase == .working || phase == .done ? model.movedBytes : selectedBytes)
        let free = model.freeBytes.map { "空き \(formatBytes($0))" } ?? ""
        switch phase {
        case .idle: subtitle.stringValue = model.status
        case .scanning: subtitle.stringValue = "調べています… \(model.items.count)件見つかりました。\nまだ何も変更していません。"
        case .ready where !model.status.isEmpty: subtitle.stringValue = model.status + (free.isEmpty ? "" : "\n" + free)
        case .ready, .confirming: subtitle.stringValue = free + "（このMacの残り）\n選んだものだけを" + (model.mode == .trash ? "ゴミ箱へ移します。" : "完全に削除します。")
        case .working: subtitle.stringValue = "\(model.doneCount) / \(model.operationCount)件 完了"
        case .done: subtitle.stringValue = free + (mode == .trash ? "\nゴミ箱を空にすると、空き容量が増えます。" : "")
        }
        scene.update(progress: model.progress, working: phase == .working, completed: phase == .done, hasData: selectedBytes > 0 || phase == .done)

        let verb = model.mode == .trash ? "ゴミ箱へ移す" : "完全に削除"
        switch phase {
        case .idle: primary.title = "調べる"
        case .scanning: primary.title = "調べるのを中止"
        case .ready: primary.title = model.selected.isEmpty ? "消すものを選んでください" : "\(verb) · \(formatBytes(selectedBytes))"
        case .confirming: primary.title = model.mode == .trash ? "ゴミ箱へ移す" : "完全に削除する"
        case .working: primary.title = "中止"
        case .done: primary.title = "一覧に戻る"
        }
        primary.isEnabled = !(phase == .ready && model.selected.isEmpty)
        let confirming = phase == .confirming
        back.isHidden = !confirming
        primary.frame = confirming ? NSRect(x: 126, y: 622, width: 248, height: 40) : NSRect(x: 26, y: 622, width: 348, height: 40)
        primary.setAccessibilityLabel(primary.title); primary.needsDisplay = true
        foot.stringValue = "削除の方法: " + (model.mode == .trash ? "ゴミ箱へ移す（あとで戻せる）" : "すぐに完全削除（戻せない）") + " · •••で変更"
    }

    func refreshList() {
        let level = model.tab
        let items = model.items(level)
        let running = model.runningApps
        let selectedHere = items.filter { model.selected.contains($0.id) }
        let busyOff = items.filter { $0.ownerIsRunning(running) && !model.selected.contains($0.id) }.count
        count.stringValue = items.isEmpty ? "" : "\(selectedHere.count) / \(items.count)件を選択" + (busyOff > 0 && level == .safe ? " · 起動中アプリの\(busyOff)件は外しています" : "")
        count.toolTip = busyOff > 0 ? "起動中のアプリが使っているものは、自動では選びません。アプリを終了してから選んでください。" : nil
        all.title = !items.isEmpty && selectedHere.count == items.count ? "すべて解除" : "すべて選択"
        all.isHidden = items.isEmpty; all.isEnabled = model.phase == .ready
        let groups = model.groups(level)
        let state = "\(model.phase)|\(level)|\(model.selected.sorted().joined(separator: ","))|\(running.count)|\(expanded.sorted().joined(separator: ","))"
        let ids = items.map(\.id)
        guard ids != shownIDs || state != shownState else { return }
        let keepScroll = level == shownLevel
        shownIDs = ids; shownState = state; shownLevel = level
        let width: CGFloat = 356
        var rows: [NSView] = []
        for group in groups {
            let key = "\(level.rawValue)|\(group.name)"
            let open = expanded.contains(key)
            rows.append(GroupRow(group: group, model: model, expanded: open, running: running, width: width) { [weak self] in
                guard let self else { return }
                if self.expanded.contains(key) { self.expanded.remove(key) } else { self.expanded.insert(key) }
                self.refresh()
            })
            if open {
                for item in group.items { rows.append(ItemRow(item: item, model: model, showsNote: group.sharedNote == nil, running: item.ownerIsRunning(running), width: width)) }
            }
        }
        let height = rows.reduce(0) { $0 + $1.frame.height }
        let content = PaperViewBase(frame: NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, height)))
        if items.isEmpty {
            let text: String
            switch model.phase {
            case .idle: text = "「調べる」を押すと、フォルダを選ばずに\nこのMac全体から候補を探します。"
            case .scanning: text = "調べています…"
            default: text = level == .safe ? "消していいものは見つかりませんでした。" : "確認が必要なものはありません。"
            }
            place(content, wrapped(text, size: 12), 16, 24, width-32, 60)
        }
        var y: CGFloat = 0
        for row in rows { row.frame.origin.y = y; y += row.frame.height; content.addSubview(row) }
        let origin = scroll.contentView.bounds.origin
        scroll.documentView = content
        if keepScroll { scroll.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, max(0, content.frame.height - scroll.contentSize.height)))) }
        else { scroll.contentView.scroll(to: .zero) }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func refreshPanel(mode: RemovalMode) {
        shownIDs = []; shownState = ""; shownLevel = nil
        panel.subviews.forEach { $0.removeFromSuperview() }
        let w: CGFloat = 348
        switch model.phase {
        case .confirming:
            let list = model.selectedItems
            place(panel, label(mode == .trash ? "この内容をゴミ箱へ移します" : "この内容を完全に削除します", size: 15, weight: .semibold), 0, 0, w, 22)
            let review = list.filter { $0.level == .review }
            place(panel, wrapped("\(list.count)件 · \(formatBytes(model.selectedBytes))" + (review.isEmpty ? "" : "（うち確認が必要なもの\(review.count)件）"), size: 12), 0, 28, w, 18)
            place(panel, textList(list.map { "• \($0.displayName)  \(formatBytes($0.bytes))" }), 0, 52, w, 170)
            var notes: [String] = []
            let running = model.runningApps
            let busy = Set(list.filter { $0.ownerIsRunning(running) }.compactMap(\.ownerName)).sorted()
            if !busy.isEmpty { notes.append("⚠︎ 起動中: \(busy.joined(separator: "、"))。該当する項目は見送ります。先に終了しておくと確実です。") }
            notes.append(mode == .trash ? "ゴミ箱へ移すだけなので、履歴から元に戻せます。空き容量はゴミ箱を空にしたときに増えます。" : "⚠︎ ゴミ箱を通さずに削除します。元に戻せません。")
            place(panel, wrapped(notes.joined(separator: "\n\n"), size: 11), 0, 232, w, 110)
        case .working:
            place(panel, label(mode == .trash ? "ゴミ箱へ移しています…" : "削除しています…", size: 15, weight: .semibold), 0, 0, w, 22)
            place(panel, wrapped("\(model.doneCount) / \(model.operationCount)件 · \(formatBytes(model.movedBytes)) / \(formatBytes(model.operationBytes))\n\n大きなフォルダは時間がかかることがあります。中止しても、処理中の1件は最後まで行います。", size: 12), 0, 30, w, 110)
        case .done:
            let r = model.result
            place(panel, label(mode == .trash ? "\(formatBytes(r.bytes))をゴミ箱へ移しました" : "\(formatBytes(r.bytes))を削除しました", size: 15, weight: .semibold), 0, 0, w, 22)
            place(panel, wrapped("\(r.moved.count)件 完了" + (r.failures.isEmpty ? "" : " · \(r.failures.count)件 見送り") + (r.stopped ? " · 途中で止めました" : ""), size: 12), 0, 28, w, 18)
            var y: CGFloat = 54
            if !r.failures.isEmpty {
                place(panel, label("見送ったもの", size: 11, weight: .semibold), 0, y, w, 16); y += 20
                place(panel, textList(r.failures), 0, y, w, 150); y += 160
            }
            if mode == .trash {
                place(panel, wrapped("空き容量は、ゴミ箱を空にすると増えます。間違えた場合は「•••」→「履歴・元に戻す」から戻せます。", size: 11), 0, y, w, 44); y += 50
                let open = actionButton("ゴミ箱を開く", target: self, action: #selector(openTrash)); place(panel, open, -4, y, 130, 30)
            }
        default: break
        }
    }

    func textList(_ lines: [String]) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 348, height: 150)); scroll.hasVerticalScroller = true; scroll.borderType = .lineBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 330, height: 150))
        text.isEditable = false; text.font = .systemFont(ofSize: 11); text.textColor = Palette.ink; text.backgroundColor = Palette.paper
        text.string = lines.joined(separator: "\n"); text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width: 4, height: 6)
        scroll.documentView = text; return scroll
    }

    @objc func tabChanged() { model.tab = tabs.selectedSegment == 0 ? .safe : .review; refresh() }
    @objc func toggleAll() { model.toggleAll(model.tab) }
    @objc func goBack() { model.cancelConfirm() }
    @objc func openTrash() { model.openTrash() }
    @objc func primaryAction() {
        switch model.phase {
        case .idle: model.scan()
        case .scanning, .working: model.stop()
        case .ready: model.beginConfirm()
        case .confirming: model.perform()
        case .done: model.finish()
        }
    }
    @objc func options(_ sender: NSButton) {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ selector: Selector, enabled: Bool = !model.isBusy) {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: ""); item.target = self; item.isEnabled = enabled
        }
        add("もう一度調べる", #selector(rescan))
        let removal = NSMenuItem(title: "削除の方法", action: nil, keyEquivalent: ""); let sub = NSMenu(); sub.autoenablesItems = false
        for (title, mode) in [("ゴミ箱へ移す（あとで戻せる）", RemovalMode.trash), ("すぐに完全削除（元に戻せない）", .delete)] {
            let item = sub.addItem(withTitle: title, action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue; item.state = model.mode == mode ? .on : .off; item.isEnabled = model.phase != .working
        }
        removal.submenu = sub; menu.addItem(removal)
        add("履歴・元に戻す…", #selector(history))
        add("調べる場所（上級者向け）…", #selector(locations))
        add("プライバシーと保護対象", #selector(privacy), enabled: true)
        menu.addItem(.separator())
        add("Moguを終了", #selector(quit), enabled: true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc func setMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = RemovalMode(rawValue: raw) else { return }
        model.mode = mode
    }
    @objc func rescan() { model.scan() }
    @objc func history() { model.showHistory() }
    @objc func locations() { model.showLocations() }
    @objc func privacy() { showPrivacy(model) }
    @objc func quit() { NSApp.terminate(nil) }
}

final class HistoryRow: PaperViewBase {
    let entry: HistoryEntry; unowned let model: AppModel
    init(entry: HistoryEntry, model: AppModel, width: CGFloat) {
        self.entry = entry; self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 112))
        let status: String = [.planned: "中断・要確認", .moved: "ゴミ箱へ移動", .deleted: "完全に削除", .failed: "見送り", .restored: "元に戻した"][entry.state]!
        place(self, label(entry.original.lastPathComponent, size: 12, weight: .semibold), 12, 8, width-150, 21)
        place(self, label("\(status) · \(entry.date.formatted(date: .abbreviated, time: .shortened))", size: 10, color: Palette.secondary), 12, 34, width-24, 18)
        let path = label(entry.original.path, size: 10, color: Palette.secondary); path.lineBreakMode = .byTruncatingMiddle; path.toolTip = entry.original.path
        place(self, path, 12, 56, width-24, 18)
        place(self, label(entry.message, size: 10, color: Palette.secondary), 12, 80, width-24, 18)
        if entry.state == .moved {
            let restore = actionButton("元に戻す", target: self, action: #selector(restore)); place(self, restore, width-109, 4, 95, 30)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func restore() { model.restore(entry) }
}

final class HistoryController: NSViewController {
    unowned let model: AppModel
    init(model: AppModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = PaperView(frame: NSRect(x: 0, y: 0, width: 750, height: 580))
        place(view, label("整理の履歴", size: 23, weight: .semibold), 26, 25, 690, 35)
        place(view, wrapped("ゴミ箱に残っているものは、元の場所へ戻せます。\n完全に削除したもの、ゴミ箱を空にしたものは戻せません。", size: 12), 27, 74, 690, 44)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 138, width: 704, height: 402)); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        do {
            let all = try model.history.load()
            let entries = Array(all.reversed().prefix(500))
            let content = PaperViewBase(frame: NSRect(x: 0, y: 0, width: 684, height: CGFloat(max(1, entries.count))*112))
            if entries.isEmpty { place(content, label("まだ何も整理していません。", size: 14, color: Palette.secondary), 12, 28, 640, 30) }
            for (i,e) in entries.enumerated() { let row = HistoryRow(entry: e, model: model, width: 684); row.frame.origin.y = CGFloat(i*112); content.addSubview(row) }
            scroll.documentView = content
            place(view, label(all.count > 500 ? "直近500件を表示しています。履歴はこのMac内に保存されます。" : "履歴とファイル名は、このMacの外には送信しません。", size: 10, color: Palette.secondary), 28, 551, 690, 18)
        } catch { place(view, wrapped("履歴を読み込めません。Finderで状態を確認してください。\n\(error.localizedDescription)"), 30, 150, 680, 120) }
        view.addSubview(scroll)
    }
}

/// Advanced: which folders are searched for development projects (node_modules, build output and so on).
final class LocationsController: NSViewController {
    unowned let model: AppModel
    let content = PaperViewBase(frame: .zero)
    init(model: AppModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = PaperView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
        place(view, label("調べる場所", size: 23, weight: .semibold), 26, 25, 500, 35)
        place(view, wrapped("開発プロジェクトの依存パッケージ（node_modules など）やビルド出力を探すフォルダです。アプリのキャッシュ、Codex / Claudeの記録、ダウンロードは、ここに関係なくいつも調べます。", size: 12), 27, 68, 506, 48)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 128, width: 512, height: 300)); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = content; view.addSubview(scroll)
        place(view, actionButton("フォルダを追加…", target: self, action: #selector(add)), 20, 440, 140, 32)
        place(view, wrapped("ホームフォルダの中のフォルダを選べます（ライブラリ、隠しフォルダ、iCloud上のフォルダを除く）。変更は、次にメニューを開いたときの調べ直しから反映されます。", size: 10.5), 28, 480, 506, 30)
        rebuild()
    }

    func rebuild() {
        content.subviews.forEach { $0.removeFromSuperview() }
        let width: CGFloat = 494, home = model.userHome.path
        func shortPath(_ url: URL) -> String { url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path }
        var y: CGFloat = 4
        place(content, label("いつもの場所", size: 12, weight: .semibold), 4, y, width, 18); y += 24
        let usual = Sweep.defaultProjectRoots(home: model.userHome), skipped = model.skippedProjectRoots
        if usual.isEmpty { place(content, label("見つかりませんでした（~/Developer、~/Projects など）", size: 11, color: Palette.secondary), 8, y, width, 18); y += 24 }
        for root in usual {
            let check = NSButton(checkboxWithTitle: shortPath(root), target: self, action: #selector(toggleUsual(_:)))
            check.state = skipped.contains(root.lastPathComponent) ? .off : .on; check.identifier = NSUserInterfaceItemIdentifier(root.lastPathComponent)
            check.font = .systemFont(ofSize: 12); check.contentTintColor = .black
            place(content, check, 6, y, width - 12, 22); y += 26
        }
        y += 12
        place(content, label("追加した場所", size: 12, weight: .semibold), 4, y, width, 18); y += 24
        let added = model.addedProjectRoots
        if added.isEmpty { place(content, label("まだありません。「フォルダを追加…」から選べます。", size: 11, color: Palette.secondary), 8, y, width, 18); y += 24 }
        for (index, root) in added.enumerated() {
            var problem: String?
            do { try Sweep.validateProjectRoot(root, home: model.userHome) } catch { problem = error.localizedDescription }
            let path = label(shortPath(root) + (problem == nil ? "" : "（今は調べられません）"), size: 12, color: problem == nil ? Palette.ink : Palette.secondary)
            path.lineBreakMode = .byTruncatingMiddle; path.toolTip = problem.map { root.path + "\n" + $0 } ?? root.path
            place(content, path, 8, y + 3, width - 90, 18)
            let remove = actionButton("外す", target: self, action: #selector(remove(_:))); remove.tag = index
            remove.setAccessibilityLabel(shortPath(root) + "を外す")
            place(content, remove, width - 76, y - 2, 72, 28); y += 30
        }
        content.frame = NSRect(x: 0, y: 0, width: width, height: y + 8)
    }

    @objc func toggleUsual(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        var skipped = model.skippedProjectRoots
        if sender.state == .on { skipped.remove(name) } else { skipped.insert(name) }
        model.skippedProjectRoots = skipped
    }
    @objc func remove(_ sender: NSButton) {
        var added = model.addedProjectRoots
        guard added.indices.contains(sender.tag) else { return }
        added.remove(at: sender.tag); model.addedProjectRoots = added; rebuild()
    }
    @objc func add() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.directoryURL = model.userHome; panel.prompt = "追加"
        panel.message = "開発プロジェクトを探すフォルダを選んでください。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            var rejected: [String] = []
            for url in panel.urls {
                do { try self.model.addProjectRoot(url) } catch { rejected.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            self.rebuild()
            if !rejected.isEmpty { self.model.alert("追加できないフォルダがあります", rejected.joined(separator: "\n")) }
        }
    }
}

func showPrivacy(_ model: AppModel) {
    model.alert("プライバシーと保護対象", "スキャンと整理はこのMac内だけで行います。ネットワーク通信や利用状況の送信はしません。\n\nMoguは、決まった場所（キャッシュ、開発プロジェクトの依存・ビルド出力、Codex / Claudeの記録、ダウンロード）だけを調べます。フォルダを選ぶ必要はありません。開発プロジェクトを探すフォルダは「•••」→「調べる場所」で変えられます。ダウンロードを初めて調べるときは、macOSが許可を確認します。\n\nGitで管理されているフォルダ、Gitリポジトリそのもの、iCloud上の項目、リンク経由の場所は対象にしません。ビルド出力は、Gitで管理されていないと確認できたものだけを「消していい」に入れます。\n\n実行前に、選んだ内容を同じメニューの中で確認します。関連アプリが起動中の項目は見送ります。削除の方法（ゴミ箱へ移す／すぐに完全削除）は「•••」→「削除の方法」で選べます。")
}
