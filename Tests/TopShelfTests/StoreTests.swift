import XCTest
@testable import TopShelf

final class StoreTests: XCTestCase {
    @MainActor
    func testDropUsesLandingPositionAndPreservesExistingLayout() throws {
        let base = try temporaryDirectory()
        let targets = ["原有", "拖入一", "拖入二"].map { base.appendingPathComponent($0) }
        for target in targets { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
        let store = ShelfStore(root: base.appendingPathComponent("data"))
        store.addShortcuts([targets[0]])
        let point = CGPoint(x: 309, y: 135)
        let preview = ShortcutLayout.availablePosition(near: point, occupied: [ShortcutPosition(x: 0, y: 0)])
        store.addShortcuts([targets[1], targets[2]], at: point, canvasWidth: 600)
        XCTAssertEqual(store.shortcuts.map(\.name), ["原有", "拖入一", "拖入二"])
        XCTAssertEqual(store.shortcuts[0].position, ShortcutPosition(x: 0, y: 0))
        XCTAssertEqual(store.shortcuts[1].position, preview)
        XCTAssertEqual(store.shortcuts[2].position, ShortcutPosition(x: preview.x, y: preview.y + 64))
        let before = store.shortcuts
        store.addShortcuts(targets, at: CGPoint(x: 0, y: 0))
        store.addShortcuts([targets[0]], at: CGPoint(x: CGFloat.nan, y: 0))
        XCTAssertEqual(store.shortcuts, before)
        XCTAssertEqual(ShelfStore(root: store.root).shortcuts, before)
    }

    @MainActor
    func testArrangementUndoRedoPreservesNoteAndRelinkAndDoesNotResurrectRemovedItems() throws {
        let base = try temporaryDirectory()
        let targets = ["甲", "乙", "新目标"].map { base.appendingPathComponent($0) }
        for target in targets { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
        let store = ShelfStore(root: base.appendingPathComponent("data"))
        store.undoManager.groupsByEvent = false
        store.addShortcuts(Array(targets.prefix(2)))
        store.addNote()
        let noteID = try XCTUnwrap(store.selectedNoteID)
        let id = store.shortcuts[0].id
        store.moveShortcut(id, to: CGPoint(x: 320, y: 192), canvasWidth: 600)
        XCTAssertTrue(store.undoManager.canUndo)
        store.updateNote(noteID, text: "排列撤销不修改便签")
        store.relinkShortcut(store.shortcuts[0], to: targets[2])
        store.undoManager.undo()
        XCTAssertNil(store.shortcuts[0].position)
        XCTAssertNil(store.shortcuts[1].position)
        XCTAssertEqual(store.shortcuts[0].path, targets[2].path)
        XCTAssertEqual(store.notes[0].text, "排列撤销不修改便签")
        store.undoManager.redo()
        XCTAssertEqual(store.shortcuts[0].position, ShortcutPosition(x: 320, y: 192))
        XCTAssertEqual(ShelfStore(root: store.root).shortcuts[0].position, store.shortcuts[0].position)
        store.removeShortcut(store.shortcuts[0])
        store.undoManager.undo()
        XCTAssertEqual(store.shortcuts.count, 1)
        XCTAssertFalse(store.shortcuts.contains { $0.id == id })
        XCTAssertTrue(targets.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func backupData(_ text: String) throws -> Data {
        try JSONEncoder().encode(ShelfSnapshot(notes: [ShelfNote(text: text)]))
    }

    func testBackupRotationKeepsThreeAndLeavesUnrelatedFilesAlone() throws {
        let root = try temporaryDirectory()
        let backups = ShelfBackups(root: root)
        let now = Date()
        for revision in 0..<7 {
            try backups.capture(backupData("版本\(revision)"), force: true, now: now.addingTimeInterval(Double(revision)))
        }
        let unrelated = backups.directory.appendingPathComponent("用户文件.txt")
        try Data("保留".utf8).write(to: unrelated)
        try backups.capture(backupData("版本7"), force: true, now: now.addingTimeInterval(7))
        let entries = try backups.list()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(try entries.map { try ShelfDisk.decode(backups.read($0)).notes[0].text }, ["版本7", "版本6", "版本5"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testBackupByteCapValidationAndOversizeNeverEvictGoodCopies() throws {
        let root = try temporaryDirectory()
        let sample = try backupData(String(repeating: "A", count: 1024))
        let backups = ShelfBackups(root: root, byteLimit: sample.count * 2 + 50, interval: 0)
        for index in 0..<5 {
            try backups.capture(backupData(String(repeating: "\(index)", count: 1024)), now: Date().addingTimeInterval(Double(index)))
        }
        let before = try backups.list()
        XCTAssertEqual(before.count, 2)
        XCTAssertLessThanOrEqual(before.reduce(0) { $0 + $1.bytes }, backups.byteLimit)
        XCTAssertThrowsError(try backups.capture(Data("broken".utf8), force: true))
        XCTAssertThrowsError(try backups.capture(backupData(String(repeating: "x", count: 4096)), force: true))
        XCTAssertEqual(try backups.list().map(\.id), before.map(\.id))
    }

    func testBackupThrottleSurvivesRestartAndSkipsReadingSource() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("shelf.json")
        let first = try backupData("最初")
        let now = Date()
        try first.write(to: file)
        let backups = ShelfBackups(root: root)
        XCTAssertTrue(try backups.captureFile(at: file, now: now))
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(try backups.captureFile(at: file, now: now.addingTimeInterval(1)))
        XCTAssertFalse(try ShelfBackups(root: root).captureFile(at: file, now: now.addingTimeInterval(2)))
        try first.write(to: file)
        XCTAssertFalse(try backups.captureFile(at: file, now: now.addingTimeInterval(301)))
        try backupData("修改").write(to: file)
        XCTAssertTrue(try backups.captureFile(at: file, now: now.addingTimeInterval(602)))
        XCTAssertEqual(try backups.list().count, 2)
    }

    @MainActor
    func testRestoreFlushesPendingEditsPreservesCurrentAndCancelsOldAutosave() async throws {
        let root = try temporaryDirectory()
        let store = ShelfStore(root: root)
        let archived = try backupData("历史便签")
        try store.backups.capture(archived, force: true)
        let selected = try XCTUnwrap(store.backups.list().first)
        store.addNote()
        let id = try XCTUnwrap(store.selectedNoteID)
        store.updateNote(id, text: "尚未自动保存的当前便签")
        let revision = store.editorRevision
        XCTAssertTrue(store.restoreBackup(selected))
        XCTAssertNotEqual(store.editorRevision, revision)
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertEqual(store.notes[0].text, "历史便签")
        let backedUp = try store.backups.list().map { try ShelfDisk.decode(store.backups.read($0)).notes.first?.text }
        XCTAssertTrue(backedUp.contains("尚未自动保存的当前便签"))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("shelf.json")), archived)
    }

    @MainActor
    func testCorruptMainCanBeRecoveredAndRawOriginalIsPreserved() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("shelf.json")
        let broken = Data("损坏原文".utf8)
        try broken.write(to: file)
        let store = ShelfStore(root: root)
        XCTAssertFalse(store.canWrite)
        try store.backups.capture(backupData("有效备份"), force: true)
        let selected = try XCTUnwrap(store.backups.list().first)
        XCTAssertTrue(store.restoreBackup(selected))
        XCTAssertTrue(store.canWrite)
        XCTAssertEqual(store.notes[0].text, "有效备份")
        let files = try FileManager.default.contentsOfDirectory(at: store.backups.directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(try files.contains { try Data(contentsOf: $0) == broken })
        XCTAssertEqual(try store.backups.list().count, 1)
    }

    @MainActor
    func testInvalidOrMissingBackupNeverReplacesCurrentData() throws {
        let root = try temporaryDirectory()
        let store = ShelfStore(root: root)
        store.addNote()
        try store.backups.capture(backupData("备份"), force: true)
        let entry = try XCTUnwrap(store.backups.list().first)
        let file = root.appendingPathComponent("shelf.json")
        let before = try Data(contentsOf: file)
        try Data("invalid".utf8).write(to: entry.url)
        XCTAssertFalse(store.restoreBackup(entry))
        XCTAssertEqual(try Data(contentsOf: file), before)
        try FileManager.default.removeItem(at: entry.url)
        XCTAssertFalse(store.restoreBackup(entry))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    @MainActor
    func testRestoreAbortsWhenCurrentFileCannotFitBackupLimit() throws {
        let root = try temporaryDirectory()
        let store = ShelfStore(root: root)
        try store.backups.capture(backupData("历史"), force: true)
        let entry = try XCTUnwrap(store.backups.list().first)
        let file = root.appendingPathComponent("shelf.json")
        let oversized = Data(repeating: 32, count: 30 * 1024 * 1024 + 1)
        try oversized.write(to: file)
        let readonly = ShelfStore(root: root)
        XCTAssertFalse(readonly.canWrite)
        XCTAssertFalse(readonly.restoreBackup(entry))
        XCTAssertEqual(try Data(contentsOf: file), oversized)
        XCTAssertEqual(try readonly.backups.list().count, 1)
    }

    func testLegacyShortcutsLoadWithoutPositionsAndUseFreeSlots() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"旧入口\",\"path\":\"/tmp/example\",\"isDirectory\":true}".utf8)
        let old = try JSONDecoder().decode(ShelfShortcut.self, from: data)
        XCTAssertNil(old.position)
        let fixed = ShelfShortcut(name: "已摆放", path: "/tmp/fixed", isDirectory: true,
                                  position: ShortcutPosition(x: 0, y: 0))
        let layout = ShortcutLayout.positions(for: [old, fixed], width: 600)
        XCTAssertEqual(layout[fixed.id], fixed.position)
        XCTAssertEqual(layout[old.id], ShortcutPosition(x: 208, y: 0))
        let narrow = ShortcutLayout.positions(for: [fixed], width: 200)
        XCTAssertEqual(narrow[fixed.id], fixed.position)
    }

    func testHiddenGridSnapsWithoutOverlappingOrGoingNegative() {
        let empty = ShortcutLayout.availablePosition(near: CGPoint(x: 101, y: 83), occupied: [])
        XCTAssertEqual(empty, ShortcutPosition(x: 96, y: 80))
        XCTAssertEqual(ShortcutLayout.availablePosition(near: CGPoint(x: -100, y: -10), occupied: []),
                       ShortcutPosition(x: 0, y: 0))
        let other = ShortcutPosition(x: 96, y: 80)
        let result = ShortcutLayout.availablePosition(near: other.point, occupied: [other])
        XCTAssertFalse(ShortcutLayout.frame(at: result).intersects(ShortcutLayout.frame(at: other)))
        XCTAssertEqual(result.x, 96)
    }

    @MainActor
    func testArrangementSurvivesRestartRelinkAndAddingAnotherShortcut() throws {
        let base = try temporaryDirectory()
        let targets = ["甲", "乙", "丙"].map { base.appendingPathComponent($0) }
        for url in targets { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let root = base.appendingPathComponent("data")
        let store = ShelfStore(root: root)
        store.addNote()
        let noteID = try XCTUnwrap(store.selectedNoteID)
        store.updateNote(noteID, text: "便签不能因排列改变")
        store.addShortcuts(Array(targets.prefix(2)))
        let first = store.shortcuts[0].id
        let second = store.shortcuts[1].id
        store.moveShortcut(first, to: CGPoint(x: 325, y: 203), canvasWidth: 700)
        let restored = ShelfStore(root: root)
        let arranged = ShortcutPosition(x: 320, y: 208)
        XCTAssertEqual(restored.shortcuts.first?.position, arranged)
        XCTAssertEqual(restored.shortcuts[1].position, ShortcutPosition(x: 208, y: 0))
        XCTAssertEqual(restored.notes.first?.text, "便签不能因排列改变")
        restored.relinkShortcut(restored.shortcuts[0], to: targets[2])
        XCTAssertEqual(restored.shortcuts[0].position, arranged)
        restored.addShortcuts([targets[0]])
        let layout = ShortcutLayout.positions(for: restored.shortcuts, width: 350)
        XCTAssertEqual(layout[first], arranged)
        XCTAssertEqual(layout[second], ShortcutPosition(x: 208, y: 0))
        XCTAssertEqual(layout[restored.shortcuts[2].id], ShortcutPosition(x: 0, y: 0))
        XCTAssertEqual(ShelfStore(root: root).shortcuts[0].position, arranged)
        XCTAssertTrue(targets.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @MainActor
    func testUnchangedMoveDoesNotRewriteFileAndInvalidCoordinatesAreIgnored() throws {
        let base = try temporaryDirectory()
        let target = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = ShelfStore(root: base.appendingPathComponent("data"))
        store.addShortcuts([target])
        let id = store.shortcuts[0].id
        store.moveShortcut(id, to: CGPoint(x: 32, y: 64), canvasWidth: 600)
        let file = store.root.appendingPathComponent("shelf.json")
        let sentinel = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: file.path)
        store.moveShortcut(id, to: CGPoint(x: 32, y: 64), canvasWidth: 600)
        store.moveShortcut(id, to: CGPoint(x: CGFloat.nan, y: 64), canvasWidth: 600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, sentinel)
    }

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
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["shelf.json", "Backups"])
        XCTAssertEqual(try store.backups.list().count, 1)
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
