import XCTest
import AppKit
@testable import TopShelf

final class DrawerTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testPhysicalDownWithNaturalTrackpadAndConventionalWheel() {
        var trackpad = TopEdgeGesture()
        XCTAssertNil(trackpad.consume(deltaY: 3, inverted: true, precise: true, momentum: false, screen: screen, time: 1))
        XCTAssertEqual(trackpad.consume(deltaY: 6, inverted: true, precise: true, momentum: false, screen: screen, time: 1.05), .open)
        var wheel = TopEdgeGesture()
        XCTAssertEqual(wheel.consume(deltaY: -1, inverted: false, precise: false, momentum: false, screen: screen, time: 1), .open)
    }

    func testOrdinaryScrollingAndMomentumCannotOpenDrawer() {
        var gesture = TopEdgeGesture()
        XCTAssertNil(gesture.consume(deltaY: 100, inverted: true, precise: true, momentum: false, screen: nil, time: 1))
        XCTAssertNil(gesture.consume(deltaY: 100, inverted: true, precise: true, momentum: true, screen: screen, time: 2))
        XCTAssertNil(gesture.consume(deltaY: 2, inverted: true, precise: true, momentum: false, screen: screen, time: 3))
    }

    func testEdgeLocationsWorkOnSecondaryScreensAndExcludeMenuContents() {
        XCTAssertTrue(TopEdgeGesture.isAtTop(CGPoint(x: 100, y: 899), screen: screen))
        XCTAssertFalse(TopEdgeGesture.isAtTop(CGPoint(x: 100, y: 880), screen: screen))
        let left = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        XCTAssertTrue(TopEdgeGesture.isAtTop(CGPoint(x: -300, y: 979), screen: left))
        XCTAssertFalse(TopEdgeGesture.isAtTop(CGPoint(x: 10, y: 979), screen: left))
        let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        XCTAssertTrue(TopEdgeGesture.isAtTop(CGPoint(x: 400, y: 1979), screen: above))
    }

    func testDirectionChangeCooldownAndReversePreference() {
        var gesture = TopEdgeGesture()
        XCTAssertEqual(gesture.consume(deltaY: 10, inverted: true, precise: true, momentum: false, screen: screen, time: 1), .open)
        XCTAssertNil(gesture.consume(deltaY: -10, inverted: true, precise: true, momentum: false, screen: screen, time: 1.1))
        XCTAssertEqual(gesture.consume(deltaY: -10, inverted: true, precise: true, momentum: false, screen: screen, time: 2), .close)
        XCTAssertEqual(gesture.consume(deltaY: -10, inverted: true, precise: true, momentum: false, screen: screen, time: 3, reversed: true), .open)
    }

    func testSwitchingScreenDoesNotCarryPartialGesture() {
        var gesture = TopEdgeGesture()
        XCTAssertNil(gesture.consume(deltaY: 5, inverted: true, precise: true, momentum: false, screen: screen, time: 1))
        let other = screen.offsetBy(dx: 1440, dy: 0)
        XCTAssertNil(gesture.consume(deltaY: 5, inverted: true, precise: true, momentum: false, screen: other, time: 1.05))
    }

    @MainActor
    func testAnimationCanReverseWithoutStaleCloseCompletion() async throws {
        let view = DrawerClipView(body: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 1080, height: 500)
        var completions: [String] = []
        view.animate(open: true, reduceMotion: false) { completions.append("old-open") }
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertGreaterThan(view.progress, 0)
        XCTAssertEqual(view.body.frame.origin.y, 0, "Animation must not reposition the editor's layout frame")
        view.animate(open: false, reduceMotion: false) { completions.append("old-close") }
        view.animate(open: true, reduceMotion: false) { completions.append("final-open") }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(view.progress, 1)
        XCTAssertEqual(view.body.frame.origin.y, 0)
        XCTAssertFalse(view.isAnimating)
        XCTAssertEqual(completions, ["final-open"])
        view.animate(open: false, reduceMotion: true) { completions.append("closed") }
        XCTAssertEqual(view.progress, 0)
        XCTAssertEqual(view.body.layer?.transform.m42, view.bounds.height)
    }

    @MainActor
    func testSuspendingHiddenDrawerPreservesEditorAndSelection() {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        editor.string = "保留便签与光标位置"
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        let drawer = DrawerClipView(body: editor)
        drawer.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: drawer.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = drawer
        XCTAssertTrue(editor.window === window)
        drawer.animate(open: true, reduceMotion: true) {}
        drawer.suspend()
        XCTAssertFalse(drawer.isSuspended, "An open drawer must stay attached")
        drawer.animate(open: false, reduceMotion: true) {}
        drawer.suspend()
        XCTAssertNil(editor.window)
        XCTAssertTrue(drawer.isSuspended)
        drawer.animate(open: true, reduceMotion: true) {}
        XCTAssertTrue(editor.window === window)
        XCTAssertTrue(drawer.body === editor)
        XCTAssertEqual(editor.string, "保留便签与光标位置")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 2))
        window.close()
    }
}
