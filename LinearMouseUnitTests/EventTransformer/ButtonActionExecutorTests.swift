// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreGraphics
@testable import GestureKit
@testable import LinearMouse
import XCTest

private final class ButtonActionTestTimerScheduler {
    final class ScheduledTimer {
        let interval: TimeInterval
        let repeats: Bool
        let handler: () -> Void
        var isActive = true

        init(interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void) {
            self.interval = interval
            self.repeats = repeats
            self.handler = handler
        }
    }

    private(set) var timers = [ScheduledTimer]()

    func schedule(
        interval: TimeInterval,
        repeats: Bool,
        handler: @escaping () -> Void
    ) -> ButtonActionExecutor.TimerToken {
        let timer = ScheduledTimer(interval: interval, repeats: repeats, handler: handler)
        timers.append(timer)
        return .init {
            timer.isActive = false
        }
    }

    func fire(_ timer: ScheduledTimer) {
        guard timer.isActive else {
            return
        }
        if !timer.repeats {
            timer.isActive = false
        }
        timer.handler()
    }
}

final class ButtonActionExecutorTests: XCTestCase {
    private typealias Mapping = Scheme.Buttons.Mapping

    private let repeatAction = Mapping.PressAction(
        action: .arg0(.none),
        behavior: .repeat
    )

    func testPinchZoomPostsCompleteNativeGestureInBothDirections() {
        for magnification in [0.1, -0.2] {
            var events = [CGEvent]()
            let scheduler = ButtonActionTestTimerScheduler()
            let executor = ButtonActionExecutor(
                postGestureEvent: { events.append($0) },
                schedulePinchZoomEnd: scheduler.schedule
            )
            executor.perform(.arg1(.pinchZoom(magnification)), targetBundleIdentifier: nil)
            let completed = expectation(description: "Action dispatched")
            DispatchQueue.main.async { completed.fulfill() }
            wait(for: [completed], timeout: 1)
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(scheduler.timers.last?.interval, 0.3)
            scheduler.timers.last.map(scheduler.fire)

            XCTAssertEqual(
                events.map { $0.getIntegerValueField(.gesturePhase) },
                [CGSGesturePhase.began, .changed, .ended].map { Int64($0.rawValue) }
            )
            // CoreGraphics stores the gesture magnification at Float precision.
            for (event, expected) in zip(events, [0, magnification, 0]) {
                XCTAssertEqual(event.getDoubleValueField(.gestureZoomValue), expected, accuracy: 0.000001)
            }
            XCTAssertTrue(events.allSatisfy {
                $0.getIntegerValueField(.gestureHIDType) == Int64(IOHIDEventType.zoom.rawValue)
                    && $0.flags.isEmpty
            })
        }
    }

    func testPinchZoomBurstKeepsOneGestureUntilIdleAndRestartsAfterward() throws {
        var events = [CGEvent]()
        let scheduler = ButtonActionTestTimerScheduler()
        let executor = ButtonActionExecutor(
            postGestureEvent: { events.append($0) },
            schedulePinchZoomEnd: scheduler.schedule
        )
        for _ in 0 ..< 6 {
            executor.perform(.arg1(.pinchZoom(0.1)), targetBundleIdentifier: "com.google.Chrome")
        }
        drainMainQueue()
        XCTAssertEqual(events.map { $0.getIntegerValueField(.gesturePhase) },
                       [1, 2, 2, 2, 2, 2, 2])
        XCTAssertTrue(scheduler.timers.dropLast().allSatisfy { !$0.isActive })
        // Even a stale callback cannot terminate a newer update's gesture.
        try XCTUnwrap(scheduler.timers.first).handler()
        XCTAssertEqual(events.count, 7)
        scheduler.fire(try XCTUnwrap(scheduler.timers.last))
        XCTAssertEqual(events.last?.getIntegerValueField(.gesturePhase), 4)

        executor.perform(.arg1(.pinchZoom(-0.1)), targetBundleIdentifier: "com.google.Chrome")
        drainMainQueue()
        XCTAssertEqual(events.suffix(2).map { $0.getIntegerValueField(.gesturePhase) }, [1, 2])
        executor.deactivate()
        drainMainQueue()
        XCTAssertEqual(events.last?.getIntegerValueField(.gesturePhase), 4)
        XCTAssertTrue(scheduler.timers.allSatisfy { !$0.isActive })
    }

    func testPinchZoomEndsBeforeChangingTargetApplication() {
        var events = [CGEvent]()
        let scheduler = ButtonActionTestTimerScheduler()
        let executor = ButtonActionExecutor(
            postGestureEvent: { events.append($0) },
            schedulePinchZoomEnd: scheduler.schedule
        )
        executor.perform(.arg1(.pinchZoom(0.1)), targetBundleIdentifier: "com.google.Chrome")
        executor.perform(.arg1(.pinchZoom(0.1)), targetBundleIdentifier: "com.apple.Safari")
        drainMainQueue()
        XCTAssertEqual(events.map { $0.getIntegerValueField(.gesturePhase) }, [1, 2, 4, 1, 2])
        executor.deactivate()
        drainMainQueue()
    }

    private func drainMainQueue() {
        let completed = expectation(description: "Actions dispatched")
        DispatchQueue.main.async { completed.fulfill() }
        wait(for: [completed], timeout: 1)
    }

    func testPinchZoomIgnoresZeroAndNonFiniteMagnification() {
        var events = [CGEvent]()
        let executor = ButtonActionExecutor(postGestureEvent: { events.append($0) })
        for magnification in [0, Double.infinity, Double.nan] {
            executor.perform(.arg1(.pinchZoom(magnification)), targetBundleIdentifier: nil)
        }
        let completed = expectation(description: "Actions dispatched")
        DispatchQueue.main.async { completed.fulfill() }
        wait(for: [completed], timeout: 1)
        XCTAssertTrue(events.isEmpty)
    }

    func testRepeatSchedulesSystemDelayAndCancelsOnRelease() throws {
        let runtimeState = ButtonActionExecutor.RuntimeState()
        let scheduler = ButtonActionTestTimerScheduler()
        let executor = makeExecutor(runtimeState: runtimeState, scheduler: scheduler)
        let buttons: Set<Mapping.Button> = [.mouse(4)]

        executor.beginPress(repeatAction, buttons: buttons, targetBundleIdentifier: nil)

        let delayTimer = try XCTUnwrap(scheduler.timers.first)
        XCTAssertEqual(delayTimer.interval, 0.4)
        XCTAssertFalse(delayTimer.repeats)
        XCTAssertTrue(delayTimer.isActive)
        XCTAssertNotNil(runtimeState.repeatTimers[buttons])

        executor.endPress(repeatAction, buttons: buttons)

        XCTAssertFalse(delayTimer.isActive)
        XCTAssertTrue(runtimeState.repeatTimers.isEmpty)
    }

    func testRepeatSwitchesFromDelayToRepeatingTimer() throws {
        let runtimeState = ButtonActionExecutor.RuntimeState()
        let scheduler = ButtonActionTestTimerScheduler()
        let executor = makeExecutor(runtimeState: runtimeState, scheduler: scheduler)
        let buttons: Set<Mapping.Button> = [.mouse(4)]

        executor.beginPress(repeatAction, buttons: buttons, targetBundleIdentifier: nil)
        try scheduler.fire(XCTUnwrap(scheduler.timers.first))

        XCTAssertEqual(scheduler.timers.count, 2)
        let repeatingTimer = scheduler.timers[1]
        XCTAssertEqual(repeatingTimer.interval, 0.05)
        XCTAssertTrue(repeatingTimer.repeats)
        XCTAssertTrue(repeatingTimer.isActive)

        executor.endPress(repeatAction, buttons: buttons)
        XCTAssertFalse(repeatingTimer.isActive)
    }

    func testIndependentRepeatsHaveIndependentTimers() {
        let runtimeState = ButtonActionExecutor.RuntimeState()
        let scheduler = ButtonActionTestTimerScheduler()
        let executor = makeExecutor(runtimeState: runtimeState, scheduler: scheduler)
        let firstButtons: Set<Mapping.Button> = [.mouse(4)]
        let secondButtons: Set<Mapping.Button> = [.mouse(5)]

        executor.beginPress(repeatAction, buttons: firstButtons, targetBundleIdentifier: nil)
        executor.beginPress(repeatAction, buttons: secondButtons, targetBundleIdentifier: nil)

        XCTAssertEqual(scheduler.timers.count, 2)
        executor.endPress(repeatAction, buttons: firstButtons)
        XCTAssertFalse(scheduler.timers[0].isActive)
        XCTAssertTrue(scheduler.timers[1].isActive)
        XCTAssertNil(runtimeState.repeatTimers[firstButtons])
        XCTAssertNotNil(runtimeState.repeatTimers[secondButtons])

        executor.endPress(repeatAction, buttons: secondButtons)
        XCTAssertFalse(scheduler.timers[1].isActive)
        XCTAssertTrue(runtimeState.repeatTimers.isEmpty)
    }

    func testDisabledSystemRepeatDefersOneActionUntilRelease() {
        let runtimeState = ButtonActionExecutor.RuntimeState()
        let scheduler = ButtonActionTestTimerScheduler()
        let executor = ButtonActionExecutor(
            runtimeState: runtimeState,
            repeatTimingProvider: { (delay: 0, interval: 0) },
            scheduleTimer: scheduler.schedule
        )
        let buttons: Set<Mapping.Button> = [.mouse(4)]

        executor.beginPress(repeatAction, buttons: buttons, targetBundleIdentifier: nil)

        XCTAssertTrue(scheduler.timers.isEmpty)
        XCTAssertNotNil(runtimeState.pendingReleaseActions[buttons])

        executor.endPress(repeatAction, buttons: buttons)
        XCTAssertTrue(runtimeState.pendingReleaseActions.isEmpty)
    }

    private func makeExecutor(
        runtimeState: ButtonActionExecutor.RuntimeState,
        scheduler: ButtonActionTestTimerScheduler
    ) -> ButtonActionExecutor {
        ButtonActionExecutor(
            runtimeState: runtimeState,
            repeatTimingProvider: { (delay: 0.4, interval: 0.05) },
            scheduleTimer: scheduler.schedule
        )
    }
}
