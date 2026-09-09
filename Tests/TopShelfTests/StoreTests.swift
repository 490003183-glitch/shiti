import XCTest
@testable import TopShelf

final class StoreTests: XCTestCase {
    func testTitlePreservesBlankLinesUnicodeAndTruncation() {
        let titles = ["", "\n\r\n", "\n\r\n标题\n正文", " \n正文",
                      String(repeating: "👨‍👩‍👧‍👦", count: 90),
                      "标题\n" + String(repeating: "很长的正文\n", count: 100_000)]
        for text in titles {
            let expected = text.split(whereSeparator: \.isNewline).first.map(String.init)
                .map { String($0.prefix(70)) } ?? "新便签"
            XCTAssertEqual(ShelfNote(text: text).title, expected)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TopShelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.resolvingSymlinksInPath()
    }

    @MainActor
    func testChineseNoteSurvivesRestart() throws {
        let root = try temporaryDirectory()
        let store = ShelfStore(root: root)
        store.addNote()
        let id = try XCTUnwrap(store.selectedNoteID)
        let body = "明天的想法 📝\n保留中文、换行与 emoji。\n第二项：文件整理"
        store.updateNote(id, text: body)
        XCTAssertTrue(store.saveNow())
        let restored = ShelfStore(root: root)
        XCTAssertEqual(restored.notes.first?.id, id)
        XCTAssertEqual(restored.notes.first?.text, body)
        XCTAssertEqual(restored.notes.first?.title, "明天的想法 📝")
    }

    @MainActor
    func testAutosaveWritesAfterTyping() async throws {
        let root = try temporaryDirectory()
        let store = ShelfStore(root: root)
        store.addNote()
        let id = try XCTUnwrap(store.selectedNoteID)
        store.updateNote(id, text: "第一次")
        store.updateNote(id, text: "最后一次输入")
        try await Task.sleep(nanoseconds: 650_000_000)
        let restored = ShelfStore(root: root)
        XCTAssertEqual(restored.notes.first?.text, "最后一次输入")
    }

    @MainActor
    func testCorruptIndexCannotBeOverwritten() throws {
        let root = try temporaryDirectory()
        let index = root.appendingPathComponent("shelf.json")
        let data = Data("this is not JSON".utf8)
        try data.write(to: index)
        let store = ShelfStore(root: root)
        XCTAssertFalse(store.canWrite)
        store.addNote()
        XCTAssertFalse(store.saveNow())
        XCTAssertEqual(try Data(contentsOf: index), data)
    }

    @MainActor
    func testRepeatedEditingDoesNotAccumulateFilesOrOldText() throws {
        let root = try temporaryDirectory()
        let store = ShelfStore(root: root)
        store.addNote()
        let id = try XCTUnwrap(store.selectedNoteID)
        for revision in 0..<50 {
            store.updateNote(id, text: "第\(revision)版\n" + String(repeating: "长便签内容", count: 1000))
            XCTAssertTrue(store.saveNow())
        }
        store.updateNote(id, text: "只保留当前文字")
        XCTAssertTrue(store.saveNow())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["shelf.json"])
        XCTAssertLessThan(try Data(contentsOf: root.appendingPathComponent("shelf.json")).count, 1024)
        XCTAssertEqual(ShelfStore(root: root).notes.first?.text, "只保留当前文字")
    }

    @MainActor
    func testUnchangedSaveAndDuplicateShortcutLeaveDataFileUntouched() throws {
        let base = try temporaryDirectory()
        let root = base.appendingPathComponent("data")
        let target = base.appendingPathComponent("资料.txt")
        try "资料".write(to: target, atomically: true, encoding: .utf8)
        let store = ShelfStore(root: root)
        store.addShortcuts([target])
        store.addNote()
        let id = try XCTUnwrap(store.selectedNoteID)
        store.updateNote(id, text: "已保存的文字")
        XCTAssertTrue(store.saveNow())
        let index = root.appendingPathComponent("shelf.json")
        let sentinel = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: index.path)
        let restored = ShelfStore(root: root)
        for _ in 0..<30 { XCTAssertTrue(restored.saveNow()) }
        restored.updateNote(id, text: "已保存的文字")
        restored.addShortcuts([target])
        XCTAssertTrue(restored.saveNow())
        let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, sentinel)
        restored.updateNote(id, text: "修改后立即收起")
        XCTAssertTrue(restored.saveNow())
        XCTAssertEqual(ShelfStore(root: root).notes.first?.text, "修改后立即收起")
    }

    @MainActor
    func testFailedSaveCanRetryWithoutAnotherEdit() throws {
        let root = try temporaryDirectory()
        let store = ShelfStore(root: root)
        store.addNote()
        let id = try XCTUnwrap(store.selectedNoteID)
        let index = root.appendingPathComponent("shelf.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        store.updateNote(id, text: "写入失败后仍需保存")
        XCTAssertFalse(store.saveNow())
        try FileManager.default.removeItem(at: index)
        XCTAssertTrue(store.saveNow())
        XCTAssertEqual(ShelfStore(root: root).notes.first?.text, "写入失败后仍需保存")
    }

    @MainActor
    func testRemovingLastEmptyNotePersistsEmptyState() throws {
        let root = try temporaryDirectory()
        let store = ShelfStore(root: root)
        store.addNote()
        store.removeNote(try XCTUnwrap(store.selectedNoteID))
        XCTAssertTrue(ShelfStore(root: root).notes.isEmpty)
    }

    func testRejectsInvalidShortcutPaths() throws {
        let root = try temporaryDirectory()
        let index = root.appendingPathComponent("shelf.json")
        let shortcut = ShelfShortcut(name: "无效入口", path: "../../outside", isDirectory: false)
        try ShelfDisk.write(ShelfSnapshot(shortcuts: [shortcut]), to: index)
        XCTAssertThrowsError(try ShelfDisk.read(from: index))
    }

    @MainActor
    func testShortcutsReferenceOriginalsWithoutCopyingOrDeleting() throws {
        let base = try temporaryDirectory()
        let source = base.appendingPathComponent("工作资料", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("项目说明.txt")
        try "保持原样 📝".write(to: file, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: file)
        let root = base.appendingPathComponent("data")
        let store = ShelfStore(root: root)
        store.addShortcuts([source, file, source, file])
        store.addShortcuts([source, file])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.shortcuts.count, 2)
        XCTAssertEqual(store.shortcuts.map(\.name), ["工作资料", "项目说明.txt"])
        XCTAssertEqual(try store.resolvedURL(store.shortcuts[0]).resolvingSymlinksInPath().path, source.path)
        XCTAssertEqual(try store.resolvedURL(store.shortcuts[1]).resolvingSymlinksInPath().path, file.path)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["shelf.json"])
        let restored = ShelfStore(root: root)
        XCTAssertEqual(restored.shortcuts, store.shortcuts)
        restored.removeShortcut(restored.shortcuts[0])
        restored.removeShortcut(restored.shortcuts[0])
        XCTAssertEqual(ShelfStore(root: root).shortcuts.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testSameNamesKeepDifferentTargets() throws {
        let base = try temporaryDirectory()
        var urls: [URL] = []
        for name in ["项目甲", "项目乙"] {
            let folder = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("说明.txt")
            try name.write(to: file, atomically: true, encoding: .utf8)
            urls.append(file)
        }
        let store = ShelfStore(root: base.appendingPathComponent("data"))
        store.addShortcuts(urls)
        XCTAssertEqual(store.shortcuts.count, 2)
        XCTAssertEqual(try store.resolvedURL(store.shortcuts[0]).resolvingSymlinksInPath().path, urls[0].path)
        XCTAssertEqual(try store.resolvedURL(store.shortcuts[1]).resolvingSymlinksInPath().path, urls[1].path)
    }

    @MainActor
    func testBookmarkFollowsRenamedTarget() throws {
        let base = try temporaryDirectory()
        let old = base.appendingPathComponent("旧名称.txt")
        let new = base.appendingPathComponent("新名称.txt")
        try "文字".write(to: old, atomically: true, encoding: .utf8)
        let store = ShelfStore(root: base.appendingPathComponent("data"))
        store.addShortcuts([old])
        try FileManager.default.moveItem(at: old, to: new)
        store.refreshShortcuts()
        XCTAssertEqual(store.shortcuts.first?.name, "新名称.txt")
        XCTAssertEqual(try store.resolvedURL(XCTUnwrap(store.shortcuts.first)).resolvingSymlinksInPath().path, new.path)
    }

    @MainActor
    func testMissingTargetCanBeRelinked() throws {
        let base = try temporaryDirectory()
        let old = base.appendingPathComponent("旧目标.txt")
        let new = base.appendingPathComponent("新目标.txt")
        try "旧".write(to: old, atomically: true, encoding: .utf8)
        try "新".write(to: new, atomically: true, encoding: .utf8)
        let store = ShelfStore(root: base.appendingPathComponent("data"))
        store.addShortcuts([old])
        let shortcut = try XCTUnwrap(store.shortcuts.first)
        try FileManager.default.removeItem(at: old)
        XCTAssertThrowsError(try store.resolvedURL(shortcut))
        store.relinkShortcut(shortcut, to: new)
        XCTAssertEqual(store.shortcuts.first?.id, shortcut.id)
        XCTAssertEqual(try store.resolvedURL(XCTUnwrap(store.shortcuts.first)).resolvingSymlinksInPath().path, new.path)
        XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), "新")
    }

    @MainActor
    func testMissingSourceReportsFailureWithoutCreatingShortcut() throws {
        let base = try temporaryDirectory()
        let store = ShelfStore(root: base.appendingPathComponent("data"))
        store.addShortcuts([base.appendingPathComponent("missing.txt")])
        XCTAssertTrue(store.shortcuts.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }
}
