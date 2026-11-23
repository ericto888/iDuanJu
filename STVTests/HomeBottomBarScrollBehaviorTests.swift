import XCTest
@testable import STV

final class HomeBottomBarScrollBehaviorTests: XCTestCase {
    func testFirstSampleDoesNotChangeVisibility() {
        var behavior = HomeBottomBarScrollBehavior()
        XCTAssertNil(behavior.update(offset: -20, at: 1.0))
        XCTAssertFalse(behavior.isHidden)
    }

    func testUpwardScrollHidesImmediately() {
        var behavior = HomeBottomBarScrollBehavior()
        XCTAssertNil(behavior.update(offset: -10, at: 1.0))
        XCTAssertEqual(behavior.update(offset: -12, at: 1.02), true)
        XCTAssertTrue(behavior.isHidden)
    }

    func testSlowDownwardScrollDoesNotReveal() {
        var behavior = HomeBottomBarScrollBehavior()
        _ = behavior.update(offset: -100, at: 1.0)
        XCTAssertNil(behavior.update(offset: -90, at: 1.1))
        XCTAssertTrue(behavior.isHidden)
    }

    func testFastDownwardFlickReveals() {
        var behavior = HomeBottomBarScrollBehavior()
        _ = behavior.update(offset: -100, at: 1.0)
        XCTAssertEqual(behavior.update(offset: -40, at: 1.1), false)
        XCTAssertFalse(behavior.isHidden)
    }

    func testReturningToTopAlwaysReveals() {
        var behavior = HomeBottomBarScrollBehavior()
        _ = behavior.update(offset: -100, at: 1.0)
        XCTAssertEqual(behavior.update(offset: -5, at: 3.0), false)
        XCTAssertFalse(behavior.isHidden)
    }

    func testSmallOffsetNoiseDoesNotChangeVisibility() {
        var behavior = HomeBottomBarScrollBehavior()
        _ = behavior.update(offset: -30, at: 1.0)
        XCTAssertNil(behavior.update(offset: -29, at: 1.01))
        XCTAssertFalse(behavior.isHidden)
    }

    func testResetClearsHistoryAndRestoresBar() {
        var behavior = HomeBottomBarScrollBehavior()
        _ = behavior.update(offset: -10, at: 1.0)
        _ = behavior.update(offset: -12, at: 1.01)
        XCTAssertTrue(behavior.isHidden)
        behavior.reset()
        XCTAssertFalse(behavior.isHidden)
        XCTAssertNil(behavior.update(offset: -80, at: 2.0))
        XCTAssertFalse(behavior.isHidden)
    }
}
