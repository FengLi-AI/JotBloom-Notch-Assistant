import CoreGraphics
import XCTest
@testable import JotBloomCore

final class IslandPresentationTests: XCTestCase {
    private func event(_ priority: IslandPriority, pending: Bool = false) -> IslandContent {
        .init(priority: priority, tone: .blue, compactText: "更新", title: "更新",
              policy: .init(seconds: 8, keepsPending: pending))
    }

    func testUrgentEventInterruptsWithoutLosingOlderEvents() {
        var queue = IslandEventQueue()
        let received = event(.received), completed = event(.completed), blocker = event(.blocker, pending: true)
        queue.enqueue(received, at: 0, presenting: true)
        queue.enqueue(completed, at: 1, presenting: true)
        queue.enqueue(blocker, at: 2, presenting: true)
        XCTAssertEqual(queue.current?.events, [blocker])
        XCTAssertEqual(queue.waiting.flatMap(\.events).count, 2)
        queue.dismissCurrent(resolved: true); queue.advance()
        XCTAssertEqual(queue.current?.events, [completed])
        queue.dismissCurrent(); queue.advance()
        XCTAssertEqual(queue.current?.events, [received])
        XCTAssertFalse(queue.hasPending)
    }

    func testSamePriorityMergesWithinWindowButQueuesAfterWindow() {
        var queue = IslandEventQueue()
        for time in [0.0, 4, 10, 10.01] { queue.enqueue(event(.reminder), at: time, presenting: true) }
        XCTAssertEqual(queue.current?.content.compactText, "3 件事有更新")
        XCTAssertEqual(queue.current?.content.actions, [.init("showUpdates", "看一下")])
        XCTAssertEqual(queue.waiting.count, 1)
    }

    func testSuppressionCombinesHeldEventsOnResume() {
        var queue = IslandEventQueue()
        queue.enqueue(event(.completed), at: 0, presenting: true)
        queue.suspend()
        queue.enqueue(event(.completed), at: 50, presenting: false)
        queue.enqueue(event(.blocker, pending: true), at: 60, presenting: false)
        XCTAssertNil(queue.current)
        queue.resume()
        XCTAssertEqual(queue.current?.priority, .blocker)
        queue.dismissCurrent(); queue.advance()
        XCTAssertEqual(queue.current?.events.count, 2)
        XCTAssertTrue(queue.hasPending, "Dismissing a card must not resolve the actual request")
    }

    func testPendingSurvivesTimeoutAndOnlyExplicitResolutionClearsIt() {
        var queue = IslandEventQueue()
        let request = event(.blocker, pending: true)
        queue.enqueue(request, at: 0, presenting: true)
        queue.enqueue(request, at: 1, presenting: true)
        XCTAssertEqual(queue.current?.events.count, 1)
        queue.dismissCurrent()
        XCTAssertTrue(queue.hasPending)
        queue.resolve([request.id]); XCTAssertFalse(queue.hasPending)
    }

    func testResolvingCancelledTaskRemovesHeldPresentation() {
        var queue = IslandEventQueue()
        let request = event(.blocker, pending: true)
        queue.enqueue(request, at: 0, presenting: true); queue.suspend()
        queue.resolve([request.id]); queue.resume()
        XCTAssertNil(queue.current); XCTAssertTrue(queue.waiting.isEmpty); XCTAssertFalse(queue.hasPending)
    }

    func testEveryEnvironmentalBlockSuppressesPresentationWithoutCompanionDependency() {
        var conditions = IslandPresentationConditions()
        XCTAssertFalse(conditions.allowsPresentation)
        conditions.fullScreenState = .windowed
        XCTAssertTrue(conditions.allowsPresentation)
        for key in [\IslandPresentationConditions.panelVisible, \.sleeping, \.screenSleeping, \.sessionInactive] {
            conditions[keyPath: key] = true; XCTAssertFalse(conditions.allowsPresentation)
            conditions[keyPath: key] = false
        }
        conditions.fullScreenState = .fullScreen; XCTAssertFalse(conditions.allowsPresentation)
    }

    func testShapeExcludesTransparentCanvasCornersAndPhysicalNotch() {
        let geometry = IslandGeometry(width: 300, height: 72, bottomRadius: 20, shoulderRadius: 15)
        let canvas = CGRect(x: 0, y: 0, width: 520, height: 302)
        let notch = CGRect(x: 170, y: 0, width: 180, height: 32)
        XCTAssertTrue(geometry.contains(CGPoint(x: 260, y: 50), canvas: canvas, excluding: notch))
        XCTAssertFalse(geometry.contains(CGPoint(x: 260, y: 16), canvas: canvas, excluding: notch))
        XCTAssertFalse(geometry.contains(CGPoint(x: 20, y: 50), canvas: canvas, excluding: notch))
        XCTAssertFalse(geometry.contains(CGPoint(x: 111, y: 71), canvas: canvas, excluding: notch))
        XCTAssertFalse(geometry.contains(CGPoint(x: 260, y: 150), canvas: canvas, excluding: notch))
    }

    func testFloatingPillHasRoundedTopAndNoShoulders() {
        let geometry = IslandGeometry(width: 300, height: 40, bottomRadius: 20, shoulderRadius: 0)
        let canvas = CGRect(x: 0, y: 0, width: 520, height: 270)
        XCTAssertTrue(geometry.contains(CGPoint(x: 260, y: 20), canvas: canvas, excluding: nil))
        XCTAssertFalse(geometry.contains(CGPoint(x: 111, y: 1), canvas: canvas, excluding: nil))
        XCTAssertFalse(geometry.contains(CGPoint(x: 100, y: 1), canvas: canvas, excluding: nil))
    }
}
