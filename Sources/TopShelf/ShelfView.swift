import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let accent = Color(red: 0.18, green: 0.51, blue: 0.46)

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var controls: ShelfControls
    @State private var fileSearch = ""
    @State private var noteSearch = ""
    @State private var showFileSearch = false
    @State private var showNoteSearch = false
    @State private var pendingNoteRemoval: ShelfNote?
    @FocusState private var editorFocused: Bool

    private var visibleNotes: [ShelfNote] {
        store.notes.filter { noteSearch.isEmpty || $0.text.localizedStandardContains(noteSearch) }
    }
    private var selectedNote: ShelfNote? { store.notes.first { $0.id == store.selectedNoteID } }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                shortcutsPane.frame(width: geometry.size.width * 0.44)
                Divider().opacity(0.5)
                notesPane
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .frame(minWidth: 860, minHeight: 350)
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
            Button("查看数据文件夹") { NSWorkspace.shared.open(store.root) }
        } message: { Text(store.errorMessage ?? "") }
        .alert("删除这条便签？", isPresented: Binding(get: { pendingNoteRemoval != nil }, set: { if !$0 { pendingNoteRemoval = nil } })) {
            Button("取消", role: .cancel) { pendingNoteRemoval = nil }
            Button("移到废纸篓", role: .destructive) {
                if let note = pendingNoteRemoval { store.removeNote(note.id) }
                pendingNoteRemoval = nil
            }
        } message: { Text("便签内容会以文本文件保留在系统废纸篓中。") }
    }

    private var windowControls: some View {
        HStack(spacing: 8) {
            Button { controls.isPinned.toggle() } label: {
                Image(systemName: controls.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(controls.isPinned ? accent : Color.secondary)
                    .frame(width: 26, height: 26)
            }.buttonStyle(.plain).help(controls.isPinned ? "取消固定：点击外部自动收起" : "固定面板，切换应用时保持打开")
            Menu {
                Toggle("登录后自动启动", isOn: Binding(get: { controls.launchAtLogin }, set: { controls.setLaunchAtLogin($0) }))
                if controls.loginStatus == .requiresApproval {
                    Button("等待批准：前往系统设置…") { controls.openLoginSettings() }
                }
                Divider()
                Toggle("屏幕顶部下拉呼出", isOn: $controls.topEdgeEnabled)
                Toggle("反转顶部滚动方向", isOn: $controls.reverseTopGesture)
                Divider()
                if let note = selectedNote {
                    Button("导出便签…") { exportNote(note) }
                    Button("删除便签…") { pendingNoteRemoval = note }
                    Divider()
                }
                Button("备份与恢复…") { controls.showBackups() }
                if let warning = store.backupWarning { Text(warning) }
                Button("打开本地数据文件夹") { NSWorkspace.shared.open(store.root) }
                Divider()
                Text("快捷键：⌃⌥空格")
                Button("退出应用") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).fixedSize().help("设置与更多操作")
            Button { controls.hide() } label: {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("收起（Esc）")
        }
    }

    private var shortcutsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("快捷访问").font(.system(size: 13, weight: .semibold))
                Spacer()
                if showFileSearch { searchField("搜索", text: $fileSearch).frame(width: 160) }
                Button { showFileSearch.toggle(); if !showFileSearch { fileSearch = "" } } label: {
                    Image(systemName: "magnifyingglass").frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("搜索快捷访问")
                Button { controls.chooseFiles() } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("添加快捷访问").disabled(!store.canWrite)
            }.frame(height: 28)
            ShortcutCanvas(store: store, search: fileSearch, relink: relink,
                           chooseFiles: controls.chooseFiles, beginInteraction: controls.beginShortcutInteraction)
        }.padding(16)
    }

    private func relink(_ shortcut: ShelfShortcut) {
        let dialog = NSOpenPanel()
        dialog.title = "重新选择快捷按钮的目标"
        dialog.prompt = "关联"
        dialog.canChooseFiles = true
        dialog.canChooseDirectories = true
        dialog.allowsMultipleSelection = false
        controls.withDialog {
            if dialog.runModal() == .OK, let url = dialog.url { store.relinkShortcut(shortcut, to: url) }
        }
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("便签").font(.system(size: 13, weight: .semibold))
                if store.saveStatus == "保存失败" || !store.canWrite {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(store.saveStatus)
                }
                Spacer()
                if showNoteSearch { searchField("搜索", text: $noteSearch).frame(width: 140) }
                Button { showNoteSearch.toggle(); if !showNoteSearch { noteSearch = "" } } label: {
                    Image(systemName: "magnifyingglass").frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("搜索便签")
                Button(action: newNote) { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).disabled(!store.canWrite).help("新建便签（⌘N）")
                Divider().frame(height: 14).padding(.horizontal, 4)
                windowControls
            }.frame(height: 28)
            if store.notes.isEmpty {
                Button(action: newNote) { Text("新建便签").font(.system(size: 13)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity).disabled(!store.canWrite)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    if store.notes.count > 1 || showNoteSearch {
                        ScrollView {
                            LazyVStack(spacing: 5) {
                                ForEach(visibleNotes) { note in
                                    Button { store.selectedNoteID = note.id } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(note.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                                .foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                            .background(store.selectedNoteID == note.id ? accent.opacity(0.12) : Color.clear,
                                                        in: RoundedRectangle(cornerRadius: 9))
                                    }.buttonStyle(.plain)
                                }
                                if visibleNotes.isEmpty { Text("没有匹配的便签").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 16) }
                            }
                        }.frame(width: 155)
                        Divider().opacity(0.5)
                    }
                    if let note = selectedNote {
                        let noteID = note.id
                        VStack(alignment: .leading, spacing: 10) {
                            ZStack(alignment: .topLeading) {
                                if note.text.isEmpty {
                                    Text("写点什么…")
                                        .font(.system(size: 14)).foregroundStyle(.tertiary).lineSpacing(7)
                                        .padding(.top, 8).padding(.leading, 6).allowsHitTesting(false)
                                }
                                TextEditor(text: Binding(
                                    get: { store.notes.first(where: { $0.id == noteID })?.text ?? "" },
                                    set: { store.updateNote(noteID, text: $0) }))
                                    .font(.system(size: 14)).lineSpacing(6)
                                    .scrollContentBackground(.hidden).focused($editorFocused)
                                    .id("\(note.id)-\(store.editorRevision)").disabled(!store.canWrite)
                            }
                        }.frame(maxWidth: .infinity)
                    } else {
                        Text("选择或新建一条便签").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }.padding(16)
    }

    private func searchField(_ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField(prompt, text: text).textFieldStyle(.plain).font(.system(size: 11))
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
    }

    private func newNote() {
        noteSearch = ""
        store.addNote()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { editorFocused = true }
    }

    private func exportNote(_ note: ShelfNote) {
        let dialog = NSSavePanel()
        dialog.allowedContentTypes = [.plainText]
        dialog.nameFieldStringValue = String(note.title.prefix(45)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".txt"
        controls.withDialog {
            if dialog.runModal() == .OK, let url = dialog.url {
                do { try note.text.write(to: url, atomically: true, encoding: .utf8) }
                catch { store.report("导出失败", error) }
            }
        }
    }
}

private final class URLCollector: @unchecked Sendable {
    private var urls: [Int: URL] = [:]
    private let lock = NSLock()
    func append(_ url: URL, index: Int) { lock.lock(); defer { lock.unlock() }; urls[index] = url }
    func values() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls.sorted { $0.key < $1.key }.map(\.value) }
}

private struct ShortcutFileDrop: DropDelegate {
    let enabled: Bool
    @Binding var active: Bool
    let update: (CGPoint?) -> Void
    let receive: ([NSItemProvider], CGPoint) -> Bool
    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [UTType.fileURL]) }
    func dropEntered(info: DropInfo) {
        active = enabled
        if enabled { update(info.location) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard enabled else { return DropProposal(operation: .forbidden) }
        if active { update(info.location) }
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { active = false; update(nil) }
    func performDrop(info: DropInfo) -> Bool {
        active = false
        update(nil)
        return enabled && receive(info.itemProviders(for: [UTType.fileURL]), info.location)
    }
}

private struct ShortcutCanvas: View {
    @ObservedObject var store: ShelfStore
    let search: String
    let relink: (ShelfShortcut) -> Void
    let chooseFiles: () -> Void
    let beginInteraction: () -> Void
    @State private var dropPreview: ShortcutPosition?
    @State private var externalDropActive = false
    @State private var dragPreview: ShortcutPosition?
    @State private var draggingID: UUID?

    private func dropOrigin(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - 2 - ShortcutLayout.tileSize.width / 2,
                y: location.y - 2 - ShortcutLayout.tileSize.height / 2)
    }

    private func receive(_ providers: [NSItemProvider], at point: CGPoint, width: CGFloat) -> Bool {
        guard store.canWrite, !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let collector = URLCollector()
        let revision = store.editorRevision
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                else if let string = item as? String { url = URL(string: string) }
                else { url = nil }
                if let url { collector.append(url, index: index) }
            }
        }
        group.notify(queue: .main) {
            // Do not append an old in-flight drop after a backup has been restored.
            guard store.editorRevision == revision else { return }
            let urls = collector.values()
            if urls.isEmpty { store.errorMessage = "没有读取到目标路径，请使用“添加快捷访问”选择文件或文件夹。" }
            else { store.addShortcuts(urls, at: point, canvasWidth: width) }
        }
        return true
    }

    var body: some View {
        GeometryReader { geometry in
            let positions = ShortcutLayout.positions(for: store.shortcuts, width: geometry.size.width - 4)
            let visible = store.shortcuts.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
            let width = max(geometry.size.width - 4, (positions.values.map { $0.x }.max() ?? 0) + ShortcutLayout.tileSize.width)
            let height = max(geometry.size.height - 4, (positions.values.map { $0.y }.max() ?? 0) + ShortcutLayout.tileSize.height + 64)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    if store.shortcuts.isEmpty {
                        Button(action: chooseFiles) {
                            Text("拖入文件夹或文件").font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(width: width, height: height)
                        }.buttonStyle(.plain).disabled(!store.canWrite)
                    }
                    ForEach(visible) { shortcut in
                        if let origin = positions[shortcut.id] {
                            ShortcutTile(shortcut: shortcut, open: { store.openShortcut(shortcut) }, move: { translation in
                                beginInteraction()
                                store.moveShortcut(shortcut.id,
                                                   to: CGPoint(x: origin.x + translation.width, y: origin.y + translation.height),
                                                   canvasWidth: geometry.size.width - 4)
                            }, dragChanged: { translation in
                                guard let translation else { dragPreview = nil; draggingID = nil; return }
                                externalDropActive = false
                                dropPreview = nil
                                draggingID = shortcut.id
                                dragPreview = ShortcutLayout.availablePosition(
                                    near: CGPoint(x: origin.x + translation.width, y: origin.y + translation.height),
                                    occupied: positions.filter { $0.key != shortcut.id }.map(\.value))
                            }, canMove: store.canWrite)
                            .frame(width: ShortcutLayout.tileSize.width, height: ShortcutLayout.tileSize.height)
                            .contextMenu {
                                Button(shortcut.isDirectory ? "打开文件夹" : "打开文件") { store.openShortcut(shortcut) }
                                Button("在 Finder 中显示") { store.openShortcut(shortcut, reveal: true) }
                                Button("重新选择目标…") { relink(shortcut) }
                                Divider()
                                Button("移除快捷按钮") { store.removeShortcut(shortcut) }
                            }
                            .offset(x: origin.x, y: origin.y)
                            .zIndex(draggingID == shortcut.id ? 1 : 0)
                        }
                    }
                    if let preview = dragPreview ?? (externalDropActive ? dropPreview : nil) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(accent.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                            .frame(width: ShortcutLayout.tileSize.width, height: ShortcutLayout.tileSize.height)
                            .offset(x: preview.x, y: preview.y).allowsHitTesting(false).zIndex(2)
                    }
                }.frame(width: width, height: height, alignment: .topLeading).padding(2)
                    .contentShape(Rectangle())
                    .coordinateSpace(name: "shortcutCanvas")
                    .onDrop(of: [UTType.fileURL], delegate: ShortcutFileDrop(enabled: store.canWrite, active: $externalDropActive, update: { point in
                        dropPreview = point.map { ShortcutLayout.availablePosition(near: dropOrigin($0), occupied: Array(positions.values)) }
                    }, receive: { providers, point in receive(providers, at: dropOrigin(point), width: geometry.size.width - 4) }))
            }
            .overlay {
                if visible.isEmpty && !store.shortcuts.isEmpty {
                    Text("没有匹配的快捷按钮").font(.system(size: 12)).foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
        }
    }
}

private struct ShortcutTile: View {
    let shortcut: ShelfShortcut
    let open: () -> Void
    let move: (CGSize) -> Void
    let dragChanged: (CGSize?) -> Void
    let canMove: Bool
    @State private var hovered = false
    @GestureState private var translation = CGSize.zero

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: shortcut.path))
                    .resizable().scaledToFit().frame(width: 24, height: 24)
                Text(shortcut.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5)
                .background(hovered ? accent.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(hovered ? 0.35 : 0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            // Measure against the stationary canvas, never the moving button.
            // The button's local space changes with offset and feeds back into
            // translation, causing it to lag behind or jump relative to the mouse.
            .highPriorityGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("shortcutCanvas"))
                .updating($translation) { value, state, transaction in
                    transaction.animation = nil
                    if canMove { state = value.translation }
                }
                .onChanged { value in if canMove { dragChanged(value.translation) } }
                .onEnded { value in
                    if canMove { move(value.translation) }
                    dragChanged(nil)
                })
            .onChange(of: translation) { if $0 == .zero { dragChanged(nil) } }
            .offset(translation)
            .zIndex(translation == .zero ? 0 : 1)
            .help(shortcut.path + "\n单击打开 · 拖动排列 · 右键管理")
            .accessibilityLabel(shortcut.name)
            .accessibilityHint(shortcut.isDirectory ? "在 Finder 中打开文件夹" : "使用默认应用打开文件")
    }
}
