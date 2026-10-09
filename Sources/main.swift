import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let popover = NSPopover()
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Moguを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: 34)
        if let button = statusItem.button {
            button.image = Crocodile.menuImage(); button.target = self; button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp]); button.toolTip = "Mogu — Macの整理"
            button.setAccessibilityLabel("Moguを開く")
        }
        popover.contentViewController = PopoverController(model: model)
        popover.behavior = .transient; popover.animates = false; popover.contentSize = NSSize(width: 400, height: 700)
        if Bundle.main.object(forInfoDictionaryKey: "MoguPreview") as? Bool == true {
            NSApp.setActivationPolicy(.regular)
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.4) { self.show() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isBusy {
            model.stop()
            model.alert("処理を中止しています", "処理中の1件を終えて履歴を保存します。処理が止まってから、もう一度終了してください。")
            return .terminateCancel
        }
        return .terminateNow
    }
    func show() {
        guard let button = statusItem.button else { return }
        model.prepare()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true); popover.contentViewController?.view.window?.makeKey()
    }
    @objc func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Moguを開く", action: #selector(openMenu), keyEquivalent: "").target = self
            menu.addItem(withTitle: "履歴・元に戻す…", action: #selector(history), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Moguを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) } else { show() }
    }
    @objc func openMenu() { show() }
    @objc func history() { model.showHistory() }
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
