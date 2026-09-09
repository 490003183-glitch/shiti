import AppKit
import Combine

#if APP_STORE
// Keep one balanced sandbox extension per shortcut while its icon/target is in use.
private final class ShortcutAccess {
    let url: URL
    private let started: Bool
    init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}
#endif

struct ShelfShortcut: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var bookmark: Data?
    var isDirectory: Bool
    var position: ShortcutPosition?
}

struct ShortcutPosition: Codable, Equatable {
    var x: Double
    var y: Double
    var point: CGPoint { CGPoint(x: x, y: y) }
    var isValid: Bool { x.isFinite && y.isFinite && x >= 0 && y >= 0 && x <= 100_000 && y <= 100_000 }
}

enum ShortcutLayout {
    static let tileSize = CGSize(width: 192, height: 48)
    static let grid: CGFloat = 16

    static func frame(at position: ShortcutPosition) -> CGRect {
        CGRect(origin: position.point, size: tileSize)
    }

    static func availablePosition(near point: CGPoint, occupied: [ShortcutPosition]) -> ShortcutPosition {
        var position = ShortcutPosition(x: Double(max(0, (point.x / grid).rounded() * grid)),
                                        y: Double(max(0, (point.y / grid).rounded() * grid)))
        // Leave a small gap and keep existing buttons where the user put them.
        while occupied.contains(where: { frame(at: $0).insetBy(dx: -4, dy: -4).intersects(frame(at: position)) }) {
            position.y += Double(tileSize.height + grid)
        }
        return position
    }

    static func positions(for shortcuts: [ShelfShortcut], width: CGFloat) -> [UUID: ShortcutPosition] {
        var result = Dictionary(uniqueKeysWithValues: shortcuts.compactMap { shortcut in
            shortcut.position.map { (shortcut.id, $0) }
        })
        let columns = max(1, Int((max(width, tileSize.width) + grid) / (tileSize.width + grid)))
        var slot = 0
        for shortcut in shortcuts where shortcut.position == nil {
            var candidate: ShortcutPosition
            repeat {
                candidate = ShortcutPosition(x: Double(slot % columns) * Double(tileSize.width + grid),
                                             y: Double(slot / columns) * Double(tileSize.height + grid))
                slot += 1
            } while result.values.contains(where: { frame(at: $0).insetBy(dx: -4, dy: -4).intersects(frame(at: candidate)) })
            result[shortcut.id] = candidate
        }
        return result
    }
}

struct ShelfNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var updatedAt = Date()

    var title: String {
        // Read only the displayed title; do not split or copy the entire note.
        var result = ""
        var count = 0
        for character in text {
            if character.isNewline {
                if count > 0 { break }
                continue
            }
            result.append(character)
            count += 1
            if count == 70 { break }
        }
        return result.isEmpty ? "新便签" : result
    }
}

struct ShelfSnapshot: Codable {
    var version = 2
    var notes: [ShelfNote] = []
    var shortcuts: [ShelfShortcut] = []
}

enum ShelfDisk {
    static func read(from url: URL) throws -> ShelfSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return ShelfSnapshot() }
        let snapshot = try JSONDecoder().decode(ShelfSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 2 else {
            throw NSError(domain: "TopShelf", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "数据版本比当前应用更新，请使用较新版本打开。"])
        }
        guard Set(snapshot.notes.map(\.id)).count == snapshot.notes.count,
              Set(snapshot.shortcuts.map(\.id)).count == snapshot.shortcuts.count,
              snapshot.shortcuts.allSatisfy({ !$0.name.isEmpty && $0.path.hasPrefix("/") && ($0.position?.isValid ?? true) }) else {
            throw NSError(domain: "TopShelf", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "索引结构不正确，原有数据未被改写。"])
        }
        return snapshot
    }

    static func write(_ snapshot: ShelfSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

}

@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var shortcuts: [ShelfShortcut] = [] {
        didSet { hasUnsavedChanges = true }
    }
    @Published private(set) var notes: [ShelfNote] = [] {
        didSet { hasUnsavedChanges = true }
    }
    @Published var selectedNoteID: UUID?
    @Published var errorMessage: String?
    @Published private(set) var saveStatus = "已保存到本机"
    @Published private(set) var canWrite = true

    let root: URL
    private let indexURL: URL
    private var pendingSave: Task<Void, Never>?
    private var hasUnsavedChanges = false
#if APP_STORE
    private var shortcutAccess: [UUID: ShortcutAccess] = [:]
#endif

    private func makeBookmark(for url: URL) throws -> Data {
#if APP_STORE
        return try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
#else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
#endif
    }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TopShelf", isDirectory: true)
        self.indexURL = self.root.appendingPathComponent("shelf.json")
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let snapshot = try ShelfDisk.read(from: indexURL)
            shortcuts = snapshot.shortcuts
            notes = snapshot.notes
            selectedNoteID = notes.first?.id
            hasUnsavedChanges = false
        } catch {
            canWrite = false
            saveStatus = "数据未载入"
            errorMessage = "无法载入本地数据，已暂停写入以保护原有内容。\n\(error.localizedDescription)"
        }
    }

    func addNote() {
        guard canWrite else { return }
        let note = ShelfNote(text: "")
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        saveNow()
    }

    func updateNote(_ id: UUID, text: String) {
        guard canWrite, let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updatedAt = Date()
        saveStatus = "正在保存…"
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            self?.saveNow()
        }
    }

    func removeNote(_ id: UUID) {
        guard canWrite, let note = notes.first(where: { $0.id == id }) else { return }
        // Keep deleted text as a readable file in the system Trash.
        do {
            if !note.text.isEmpty {
                let removed = root.appendingPathComponent("Deleted Notes", isDirectory: true)
                try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
                let backup = removed.appendingPathComponent("便签-\(id.uuidString).txt")
                try note.text.write(to: backup, atomically: true, encoding: .utf8)
                try FileManager.default.trashItem(at: backup, resultingItemURL: nil)
            }
            notes.removeAll { $0.id == id }
            if selectedNoteID == id { selectedNoteID = notes.first?.id }
            saveNow()
        } catch { report("无法将便签移到废纸篓", error) }
    }

    @discardableResult
    func saveNow() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        guard canWrite else { return false }
        guard hasUnsavedChanges else { return true }
        do {
            try ShelfDisk.write(ShelfSnapshot(notes: notes, shortcuts: shortcuts), to: indexURL)
            hasUnsavedChanges = false
            saveStatus = "已保存到本机"
            return true
        } catch {
            saveStatus = "保存失败"
            report("保存失败，当前内容仍保留在窗口中", error)
            return false
        }
    }

    func addShortcuts(_ urls: [URL]) {
        guard canWrite else { return }
        var existing = Set(shortcuts.map { (try? resolvedURL($0))?.resolvingSymlinksInPath().path ?? URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
        var failures: [String] = []
        for url in urls {
            do {
                guard url.isFileURL else { throw shortcutError("请选择本机或已挂载磁盘上的文件或文件夹。") }
                let source = url.standardizedFileURL
                let scope = source.startAccessingSecurityScopedResource()
                defer { if scope { source.stopAccessingSecurityScopedResource() } }
                let values = try source.resourceValues(forKeys: [.isDirectoryKey])
                guard !existing.contains(source.resolvingSymlinksInPath().path) else { continue }
                let bookmark = try makeBookmark(for: source)
                shortcuts.append(ShelfShortcut(name: source.lastPathComponent.isEmpty ? source.path : source.lastPathComponent,
                                                path: source.path, bookmark: bookmark, isDirectory: values.isDirectory == true))
                existing.insert(source.resolvingSymlinksInPath().path)
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        saveNow()
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func resolvedURL(_ shortcut: ShelfShortcut) throws -> URL {
        if let bookmark = shortcut.bookmark {
            var stale = false
            var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
#if APP_STORE
            options.insert(.withSecurityScope)
#endif
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: options,
                                       relativeTo: nil, bookmarkDataIsStale: &stale), resolved.isFileURL {
#if APP_STORE
                let access = ShortcutAccess(resolved)
                guard FileManager.default.fileExists(atPath: resolved.path) else {
                    shortcutAccess[shortcut.id] = nil
                    throw shortcutError("无法访问“\(shortcut.name)”，请在按钮菜单中重新选择目标以授权访问。")
                }
                shortcutAccess[shortcut.id] = access
#else
                guard FileManager.default.fileExists(atPath: resolved.path) else {
                    throw shortcutError("找不到“\(shortcut.name)”，请在按钮菜单中重新选择目标。")
                }
#endif
                if stale, let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }),
                   let renewed = try? makeBookmark(for: resolved) {
                    shortcuts[index].bookmark = renewed
                    saveNow()
                }
                return resolved
            }
        }
        let url = URL(fileURLWithPath: shortcut.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw shortcutError("找不到“\(shortcut.name)”。原文件可能已移动、删除或所在磁盘尚未连接。可在按钮菜单中重新选择目标。")
        }
        return url
    }

    func refreshShortcuts() {
        guard canWrite else { return }
        var changed = false
        for index in shortcuts.indices {
            guard let url = try? resolvedURL(shortcuts[index]) else { continue }
            let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            if url.path != shortcuts[index].path || name != shortcuts[index].name {
                shortcuts[index].path = url.path
                shortcuts[index].name = name
                shortcuts[index].bookmark = (try? makeBookmark(for: url)) ?? shortcuts[index].bookmark
                changed = true
            }
        }
        if changed { saveNow() }
    }

    func openShortcut(_ shortcut: ShelfShortcut, reveal: Bool = false) {
        do {
            let url = try resolvedURL(shortcut)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else if !NSWorkspace.shared.open(url) { throw shortcutError("没有可用于打开“\(shortcut.name)”的应用。") }
            refreshShortcuts()
        } catch { errorMessage = error.localizedDescription }
    }

    func removeShortcut(_ shortcut: ShelfShortcut) {
        guard canWrite, shortcuts.contains(where: { $0.id == shortcut.id }) else { return }
        // Remove metadata only: never touch the referenced target.
        shortcuts.removeAll { $0.id == shortcut.id }
#if APP_STORE
        shortcutAccess[shortcut.id] = nil
#endif
        saveNow()
    }

    func moveShortcut(_ id: UUID, to point: CGPoint, canvasWidth: CGFloat) {
        guard canWrite, shortcuts.contains(where: { $0.id == id }),
              point.x.isFinite, point.y.isFinite, canvasWidth.isFinite else { return }
        var positions = ShortcutLayout.positions(for: shortcuts, width: canvasWidth)
        let occupied = positions.filter { $0.key != id }.map(\.value)
        let position = ShortcutLayout.availablePosition(near: point, occupied: occupied)
        guard position.isValid else { return }
        positions[id] = position
        for index in shortcuts.indices {
            if let saved = positions[shortcuts[index].id], shortcuts[index].position != saved {
                shortcuts[index].position = saved
            }
        }
        saveNow()
    }

    func relinkShortcut(_ shortcut: ShelfShortcut, to url: URL) {
        guard canWrite, let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        do {
            guard url.isFileURL else { throw shortcutError("请选择文件或文件夹。") }
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let bookmark = try makeBookmark(for: url)
            shortcuts[index] = ShelfShortcut(id: shortcut.id, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                                             path: url.path, bookmark: bookmark, isDirectory: values.isDirectory == true,
                                             position: shortcuts[index].position)
#if APP_STORE
            shortcutAccess[shortcut.id] = nil
#endif
            saveNow()
        } catch { report("无法更新快捷访问", error) }
    }

    private func shortcutError(_ message: String) -> NSError {
        NSError(domain: "TopShelf.Shortcut", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func report(_ title: String, _ error: Error) { errorMessage = "\(title)。\n\(error.localizedDescription)" }
}
