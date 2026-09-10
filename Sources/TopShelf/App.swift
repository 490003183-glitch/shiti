import AppKit
import Carbon
import OSLog
import ServiceManagement
import SwiftUI

private var applicationDisplayName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "拾屉"
}

@MainActor
final class ShelfControls: ObservableObject {
    @Published var isPinned = false {
        didSet { if isPinned != oldValue { delegate?.updateEventMonitors() } }
    }
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        if loginStatus != status { loginStatus = status }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            delegate?.store.errorMessage = "无法更改登录启动设置：\(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @Published var topEdgeEnabled = UserDefaults.standard.object(forKey: "topEdgeEnabled") as? Bool ?? true {
        didSet {
            guard topEdgeEnabled != oldValue else { return }
            UserDefaults.standard.set(topEdgeEnabled, forKey: "topEdgeEnabled")
            delegate?.updateEventMonitors()
        }
    }
    @Published var reverseTopGesture = UserDefaults.standard.bool(forKey: "reverseTopGesture") {
        didSet { UserDefaults.standard.set(reverseTopGesture, forKey: "reverseTopGesture") }
    }
    weak var delegate: AppDelegate?
    func hide() { delegate?.hidePanel() }
    func chooseFiles() { delegate?.chooseFiles() }
    func showBackups() { delegate?.showBackups() }
    func beginShortcutInteraction() { delegate?.focusShortcuts() }
    func withDialog(_ action: () -> Void) {
        delegate?.dialogOpen = true
        defer { delegate?.dialogOpen = false }
        action()
    }
}

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Selection only: no text copies retained, polling, observers, or disk writes.
@MainActor
final class NoteSelection {
    private weak var previousEditor: NSTextView?
    private var previousRange: NSRange?

    func reset() { previousEditor = nil; previousRange = nil }

    @discardableResult
    func select(in editor: NSTextView) -> Bool {
        guard !editor.isFieldEditor, editor.isSelectable, !editor.hasMarkedText() else { reset(); return false }
        let text = editor.string as NSString
        var bodyStart = 0
        if text.length > 0 {
            text.getLineStart(nil, end: &bodyStart, contentsEnd: nil, for: NSRange(location: 0, length: 0))
        }
        let repeated = previousEditor === editor && previousRange == editor.selectedRange()
        let range = repeated ? NSRange(location: 0, length: text.length)
            : NSRange(location: bodyStart, length: text.length - bodyStart)
        editor.setSelectedRange(range)
        previousEditor = editor
        previousRange = range
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = ShelfStore()
    let controls = ShelfControls()
    private var panel: ShelfPanel!
    private var drawer: DrawerClipView!
    private var isPresented = false
    private weak var suspendedResponder: NSResponder?
    private var edgeGesture = TopEdgeGesture()
    private let drawerLog = Logger(subsystem: "local.topshelf.mac", category: "Drawer")
    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var dragStartChangeCount = NSPasteboard(name: .drag).changeCount
    private var statusItem: NSStatusItem!
    private var globalClickMonitor: Any?
    private var globalClickMask: NSEvent.EventTypeMask = []
    private var outsideClickDismissal = OutsideClickDismissal()
    private var localKeyMonitor: Any?
    private let noteSelection = NoteSelection()
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    var dialogOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controls.delegate = self
        setupMenu()
        setupPanel()
        setupStatusItem()
        setupHotKey()
        updateEventMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.dialogOpen else { return event }
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() {
                self.noteSelection.reset()
                return event // Candidate selection, Esc, and shortcuts belong to the IME.
            }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if modifiers == .command, key == "a", event.window === self.panel, self.panel.attachedSheet == nil,
               let editor = self.panel.firstResponder as? NSTextView, !editor.isFieldEditor {
                if self.noteSelection.select(in: editor) { return nil }
            }
            // Copy can sit between the two select-all presses; editing or cursor
            // keys start a fresh selection cycle. Mouse selection is range-checked.
            if !(modifiers == .command && key == "c") { self.noteSelection.reset() }
            guard event.keyCode == 53 else { return event }
            self.hidePanel()
            return nil
        }
        showPanel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controls.refreshLoginStatus()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if !isPresented { NSApp.mainMenu = nil }
    }

    private func setupPanel() {
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 500),
                           styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = applicationDisplayName
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.toolbar = nil
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.minSize = NSSize(width: 860, height: 430)
        panel.maxSize = NSSize(width: 10000, height: 2000)
        panel.delegate = self
        drawer = DrawerClipView(body: NSHostingView(rootView: ShelfView(store: store, controls: controls)))
        panel.contentView = drawer
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tray.2", accessibilityDescription: applicationDisplayName)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "\(applicationDisplayName)（⌃⌥空格）"
        }
    }

    private func setupMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于\(applicationDisplayName)", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出\(applicationDisplayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "新建便签", action: #selector(newNote), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "添加快捷访问…", action: #selector(chooseFiles), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "保存便签", action: #selector(save), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "收起面板", action: #selector(hidePanel), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAll = edit.addItem(withTitle: "全选", action: #selector(selectNoteText), keyEquivalent: "a")
        selectAll.target = self
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePanel() }
            return noErr
        }, 1, &eventType, context, &hotKeyHandler)
        let id = EventHotKeyID(signature: 0x54534846, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                                        GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            store.errorMessage = "⌃⌥空格快捷键注册失败，可能已被其他应用占用。仍可使用菜单栏图标打开。"
        }
    }

    private func setupTopEdge() {
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged]) { [weak self] event in
            // AppKit invokes event monitors on the main thread.
            MainActor.assumeIsolated { _ = self?.handleTopEdge(event) }
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if self?.handleTopEdge(event) == true { return nil }
            return event
        }
    }

    func updateEventMonitors() {
        outsideClickDismissal = OutsideClickDismissal()
        if controls.topEdgeEnabled {
            if globalScrollMonitor == nil { setupTopEdge() }
        } else {
            if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
            if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
            globalScrollMonitor = nil
            localScrollMonitor = nil
            edgeGesture = TopEdgeGesture()
        }

        let mask = Self.clickMonitorMask(topEdgeEnabled: controls.topEdgeEnabled,
                                         presented: isPresented, pinned: controls.isPinned)
        guard mask != globalClickMask else { return }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        globalClickMonitor = nil
        globalClickMask = mask
        guard !mask.isEmpty else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.controls.topEdgeEnabled, event.type == .leftMouseDown {
                    self.dragStartChangeCount = NSPasteboard(name: .drag).changeCount
                }
                guard self.isPresented, !self.controls.isPinned, !self.dialogOpen else { return }
                if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() {
                    // The candidate window can be outside our frame and belongs
                    // to another process. Ignore this press/release pair.
                    self.outsideClickDismissal = OutsideClickDismissal()
                    return
                }
                // Finder owns the initial press/drag. Keep the drawer available
                // until release, and never dismiss a drop landing inside it.
                let inside = self.panel.frame.contains(NSEvent.mouseLocation)
                if self.outsideClickDismissal.consume(event.type, insidePanel: inside) {
                    self.hidePanel()
                }
            }
        }
    }

    static func clickMonitorMask(topEdgeEnabled: Bool, presented: Bool, pinned: Bool) -> NSEvent.EventTypeMask {
        var mask: NSEvent.EventTypeMask = topEdgeEnabled ? [.leftMouseDown] : []
        if presented && !pinned { mask.formUnion([.leftMouseDown, .leftMouseUp, .rightMouseDown]) }
        return mask
    }

    private func handleTopEdge(_ event: NSEvent) -> Bool {
        guard controls.topEdgeEnabled, !dialogOpen else { return false }
        let point: NSPoint
        if let location = event.cgEvent?.location, let primary = NSScreen.screens.first {
            point = NSPoint(x: location.x, y: primary.frame.maxY - location.y)
        } else {
            point = NSEvent.mouseLocation
        }
        let screen = NSScreen.screens.first { TopEdgeGesture.isAtTop(point, screen: $0.frame) }
        if event.type == .leftMouseDragged {
            let board = NSPasteboard(name: .drag)
            guard let screen, !isPresented, board.changeCount != dragStartChangeCount,
                  board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return false }
            drawerLog.notice("Opening drawer from top-edge file drag")
            showPanel(on: screen, activate: false)
            return true
        }
        let intent = edgeGesture.consume(deltaY: event.scrollingDeltaY, inverted: event.isDirectionInvertedFromDevice,
                                         precise: event.hasPreciseScrollingDeltas, momentum: !event.momentumPhase.isEmpty,
                                         screen: screen?.frame, time: event.timestamp, reversed: controls.reverseTopGesture)
        guard let intent else { return false }
        switch intent {
        case .open:
            if let screen, !isPresented || panel.screen != screen {
                drawerLog.notice("Opening drawer from top-edge downward scroll")
                showPanel(on: screen)
            }
        case .close:
            if isPresented && !controls.isPinned {
                drawerLog.notice("Closing drawer from top-edge upward scroll")
                hidePanel()
            }
        }
        return true
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开\(applicationDisplayName)", action: #selector(togglePanel), keyEquivalent: "")
            menu.addItem(withTitle: "添加快捷访问…", action: #selector(chooseFiles), keyEquivalent: "")
            menu.addItem(withTitle: "新建便签", action: #selector(newNote), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出\(applicationDisplayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
            if let button = statusItem.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
        } else { togglePanel() }
    }

    @objc func togglePanel() { isPresented ? hidePanel() : showPanel() }

    func showPanel(on targetScreen: NSScreen? = nil, activate: Bool = true) {
        controls.refreshLoginStatus()
        let screen = targetScreen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        if NSApp.mainMenu == nil { setupMenu() }
        drawer.resume()
        store.refreshShortcuts()
        let bounds = screen.visibleFrame
        let widthFraction = UserDefaults.standard.object(forKey: "drawerWidthFraction") as? Double ?? 1
        let savedHeight = UserDefaults.standard.double(forKey: "panelHeight")
        let availableWidth = bounds.width - 24
        let width = min(availableWidth, max(860, availableWidth * max(0.5, min(1, widthFraction))))
        panel.maxSize = NSSize(width: availableWidth, height: bounds.height - 24)
        let height = min(savedHeight > 0 ? savedHeight : 500, bounds.height - 32)
        panel.setFrame(NSRect(x: bounds.midX - width / 2, y: bounds.maxY - height - 6, width: width, height: height), display: true)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            if let suspendedResponder { panel.makeFirstResponder(suspendedResponder) }
        } else {
            panel.orderFrontRegardless()
        }
        guard !isPresented else { return }
        isPresented = true
        updateEventMonitors()
        panel.hasShadow = false
        drawer.animate(open: true) { [weak self] in
            guard let self, self.isPresented else { return }
            self.panel.hasShadow = true
        }
    }

    @objc func hidePanel() {
        guard !dialogOpen, isPresented else { return }
        let responder = panel.firstResponder
        // End the input session before saving, including Chinese IME composition.
        guard panel.makeFirstResponder(nil) else { return }
        if store.canWrite && !store.saveNow() {
            panel.makeFirstResponder(responder)
            return
        }
        if let view = responder as? NSView, view.isDescendant(of: drawer.body) {
            suspendedResponder = responder
        }
        isPresented = false
        updateEventMonitors()
        panel.hasShadow = false
        drawer.animate(open: false) { [weak self] in
            guard let self, !self.isPresented else { return }
            self.panel.orderOut(nil)
            self.drawer.suspend()
            // No application menu is needed while the drawer is hidden.
            // Recreate it on show; the global hotkey and status menu remain active.
            if !NSApp.isActive { NSApp.mainMenu = nil }
        }
    }

    @objc func chooseFiles() {
        showPanel()
        let dialog = NSOpenPanel()
        dialog.title = "添加快捷访问"
        dialog.message = "选择文件夹或文件，添加带名称的快捷按钮。"
        dialog.prompt = "添加按钮"
        dialog.canChooseFiles = true
        dialog.canChooseDirectories = true
        dialog.allowsMultipleSelection = true
        controls.withDialog {
            if dialog.runModal() == .OK { store.addShortcuts(dialog.urls) }
        }
    }

    @objc func newNote() { showPanel(); store.addNote() }
    @objc func selectNoteText() {
        if NSApp.keyWindow === panel, panel.attachedSheet == nil,
           let editor = panel.firstResponder as? NSTextView, noteSelection.select(in: editor) { return }
        noteSelection.reset()
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { store.undoManager }
    func focusShortcuts() { panel.makeFirstResponder(drawer) }
    @objc func undo(_ sender: Any?) { store.undoManager.undo() }
    @objc func redo(_ sender: Any?) { store.undoManager.redo() }

    @objc func showBackups() {
        guard panel.makeFirstResponder(nil) else { return }
        if store.canWrite && !store.saveNow() { return }
        controls.withDialog {
            do {
                let entries = try store.backups.list()
                let alert = NSAlert()
                alert.messageText = "备份与恢复"
                alert.informativeText = "最多保留 3 份备份，合计不超过 30 MiB。有修改时最多每 5 分钟自动备份一次。恢复前会保留当前文件。\n" + (store.backupWarning ?? "")
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 450, height: 28))
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .medium
                for entry in entries {
                    picker.addItem(withTitle: "\(formatter.string(from: entry.date)) · \(entry.noteCount) 条便签 · \(entry.shortcutCount) 个入口 · \(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))")
                }
                if entries.isEmpty {
                    alert.informativeText += "\n暂无可恢复的有效备份。首次修改已有数据时会自动创建。"
                    alert.addButton(withTitle: "知道了")
                } else {
                    alert.accessoryView = picker
                    alert.addButton(withTitle: "恢复所选备份…")
                    alert.addButton(withTitle: "取消")
                }
                alert.addButton(withTitle: "查看备份文件夹")
                let response = alert.runModal()
                if (!entries.isEmpty && response == .alertThirdButtonReturn) || (entries.isEmpty && response == .alertSecondButtonReturn) {
                    try FileManager.default.createDirectory(at: store.backups.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(store.backups.directory)
                } else if !entries.isEmpty && response == .alertFirstButtonReturn {
                    let selected = entries[picker.indexOfSelectedItem]
                    let confirm = NSAlert()
                    confirm.alertStyle = .warning
                    confirm.messageText = "恢复这份备份？"
                    confirm.informativeText = "当前全部便签、快捷入口及排列将替换为 \(formatter.string(from: selected.date)) 的内容（\(selected.noteCount) 条便签、\(selected.shortcutCount) 个入口）。恢复前会保留当前文件，便于回退。"
                    confirm.addButton(withTitle: "恢复")
                    confirm.addButton(withTitle: "取消")
                    if confirm.runModal() == .alertFirstButtonReturn { store.restoreBackup(selected) }
                }
            } catch { store.report("无法读取备份", error) }
        }
    }

    @objc func save() { store.saveNow() }
    @objc func screenChanged() { if isPresented { showPanel() } }
    @objc func showAbout() {
        controls.withDialog {
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: applicationDisplayName,
                .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.2",
                .credits: NSAttributedString(string: "快捷访问与随手便签\n所有内容保存在本机。")
            ])
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard isPresented, let screen = panel.screen else { return }
        UserDefaults.standard.set(panel.frame.width / (screen.visibleFrame.width - 24), forKey: "drawerWidthFraction")
        UserDefaults.standard.set(panel.frame.height, forKey: "panelHeight")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store.canWrite && !store.saveNow() {
            showPanel()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        drawer.stop()
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }
}

@main
enum TopShelfMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
