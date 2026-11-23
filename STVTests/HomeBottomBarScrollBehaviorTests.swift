import XCTest
@testable import STV

final class HomeChromeScrollBehaviorTests: XCTestCase {
    func testIdleGeometryChangesDoNotChangeVisibility() {
        var behavior = HomeChromeScrollBehavior()
        XCTAssertNil(behavior.update(offset: -20, at: 1.0))
        XCTAssertFalse(behavior.isHidden)
    }

    func testUpwardUserScrollHidesBothChromeElements() {
        var behavior = HomeChromeScrollBehavior()
        behavior.setInteracting(true)
        XCTAssertNil(behavior.update(offset: -10, at: 1.0))
        XCTAssertEqual(behavior.update(offset: -12, at: 1.02), true)
        XCTAssertTrue(behavior.isHidden)
    }

    func testSlowDownwardUserScrollDoesNotReveal() {
        var behavior = HomeChromeScrollBehavior()
        behavior.setInteracting(true)
        _ = behavior.update(offset: 0, at: 0.9)
        XCTAssertEqual(behavior.update(offset: -100, at: 1.0), true)
        XCTAssertNil(behavior.update(offset: -90, at: 1.1))
        XCTAssertTrue(behavior.isHidden)
    }

    func testFastDownwardFlickReveals() {
        var behavior = HomeChromeScrollBehavior()
        behavior.setInteracting(true)
        _ = behavior.update(offset: 0, at: 0.9)
        _ = behavior.update(offset: -100, at: 1.0)
        XCTAssertEqual(behavior.update(offset: -40, at: 1.1), false)
        XCTAssertFalse(behavior.isHidden)
    }

    func testContentLoadingOffsetJumpDoesNotReveal() {
        var behavior = HomeChromeScrollBehavior()
        behavior.setInteracting(true)
        _ = behavior.update(offset: 0, contentHeight: 2_000, viewportHeight: 700, at: 0.9)
        XCTAssertEqual(behavior.update(offset: -100, contentHeight: 2_000, viewportHeight: 700, at: 1.0), true)
        XCTAssertNil(behavior.update(offset: -20, contentHeight: 2_800, viewportHeight: 700, at: 1.1))
        XCTAssertNil(behavior.update(offset: -15, contentHeight: 2_800, viewportHeight: 700, at: 1.2))
        XCTAssertTrue(behavior.isHidden)
    }

    func testHeaderCollapseViewportChangeDoesNotReveal() {
        var behavior = HomeChromeScrollBehavior()
        behavior.setInteracting(true)
        _ = behavior.update(offset: 0, contentHeight: 2_000, viewportHeight: 700, at: 0.9)
        _ = behavior.update(offset: -100, contentHeight: 2_000, viewportHeight: 700, at: 1.0)
        XCTAssertTrue(behavior.isHidden)
        XCTAssertNil(behavior.update(offset: -80, contentHeight: 2_000, viewportHeight: 750, at: 1.1))
        XCTAssertNil(behavior.update(offset: -75, contentHeight: 2_000, viewportHeight: 750, at: 1.2))
        XCTAssertTrue(behavior.isHidden)
    }

    func testMomentumAfterFingerReleaseCannotReveal() {
        var behavior = HomeChromeScrollBehavior()
        behavior.setInteracting(true)
        _ = behavior.update(offset: 0, at: 0.9)
        _ = behavior.update(offset: -10, at: 1.0)
        XCTAssertTrue(behavior.isHidden)
        behavior.setInteracting(false)
        XCTAssertNil(behavior.update(offset: -30, at: 1.1))
        XCTAssertTrue(behavior.isHidden)
    }

    func testReturningToTopDuringUserInteractionReveals() {
        var behavior = HomeChromeScrollBehavior()
        behavior.setInteracting(true)
        _ = behavior.update(offset: 0, at: 0.9)
        _ = behavior.update(offset: -100, at: 1.0)
        XCTAssertEqual(behavior.update(offset: -5, at: 1.1), false)
        XCTAssertFalse(behavior.isHidden)
    }

    func testResetClearsHistoryAndRestoresChrome() {
        var behavior = HomeChromeScrollBehavior()
        behavior.setInteracting(true)
        _ = behavior.update(offset: -10, at: 1.0)
        _ = behavior.update(offset: -12, at: 1.01)
        XCTAssertTrue(behavior.isHidden)
        behavior.reset()
        XCTAssertFalse(behavior.isHidden)
        XCTAssertNil(behavior.update(offset: -80, at: 2.0))
        XCTAssertFalse(behavior.isHidden)
    }
}
