// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Carbon
import Foundation
import GestureKit
import KeyKit
import os.log

class ModifierActionsTransformer {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "ModifierActionsTransformer"
    )

    private static let defaultKeySimulator = KeySimulator(
        eventSourceUserData: CGEvent.linearMouseSyntheticEventUserData
    )

    static let zoomShortcutResolver = KeyEquivalentResolver(keyEquivalents: ["+", "-"])

    typealias Modifiers = Scheme.Scrolling.Bidirectional<Scheme.Scrolling.Modifiers>
    typealias Action = Scheme.Scrolling.Modifiers.Action

    private let horizontalAction: Scheme.Scrolling.HorizontalAction
    private let postGestureEvent: (CGEvent) -> Void
    private let scheduleEnd: (TimeInterval, @escaping () -> Void) -> EventThreadTimer?
    private var endTimer: EventThreadTimer?
    private var endGeneration: UInt64 = 0
    private var defaultHorizontalPinch = false
    private var pinchAxis: ScrollInput.Axis = .vertical
    private let modifiers: Modifiers
    private let keySimulator: KeySimulating
    private let scrollGesture: ScrollGestureOwnership
    private let scrollThrottle: ScrollActionThrottle
    private let monotonicClock: () -> UInt64
    private let zoomShortcut: (Bool) -> KeyEquivalentResolver.Shortcut?

    private var pinchZoomBegan = false
    private var pinchZoomReversed = false

    init(
        modifiers: Modifiers,
        horizontalAction: Scheme.Scrolling.HorizontalAction = .scroll,
        postGestureEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
        scheduleEnd: @escaping (TimeInterval, @escaping () -> Void) -> EventThreadTimer? = {
            EventThread.shared.scheduleTimer(interval: $0, repeats: false, handler: $1)
        },
        keySimulator: KeySimulating? = nil,
        scrollThrottle: ScrollActionThrottle = .init(),
        scrollGesture: ScrollGestureOwnership = .init(),
        monotonicClock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        zoomShortcut: @escaping (Bool) -> KeyEquivalentResolver.Shortcut? = defaultZoomShortcut
    ) {
        self.horizontalAction = horizontalAction
        self.postGestureEvent = postGestureEvent
        self.scheduleEnd = scheduleEnd
        self.modifiers = modifiers
        self.keySimulator = keySimulator ?? Self.defaultKeySimulator
        self.scrollThrottle = scrollThrottle
        self.scrollGesture = scrollGesture
        self.monotonicClock = monotonicClock
        self.zoomShortcut = zoomShortcut
    }

    static func defaultZoomShortcut(zoomIn: Bool) -> KeyEquivalentResolver.Shortcut? {
        if #available(macOS 12, *) {
            return zoomShortcutResolver.shortcut(for: zoomIn ? "+" : "-")
        }
        // Preserve the legacy behavior on systems without AppKit's automatic shortcut localization.
        return .init(
            keyCode: CGKeyCode(zoomIn ? kVK_ANSI_KeypadPlus : kVK_ANSI_KeypadMinus),
            modifierFlags: .maskCommand
        )
    }
}

extension ModifierActionsTransformer: EventTransformer {
    var handlesPointerMotion: Bool {
        false
    }

    func transform(_ event: CGEvent, in _: EventTransformerContext) -> CGEvent? {
        if pinchZoomBegan {
            if defaultHorizontalPinch, event.type == .scrollWheel,
               ScrollWheelEventView(event).deltaYPt != 0 {
                endPinchZoom()
            } else if defaultHorizontalPinch, event.type != .scrollWheel, event.type != .flagsChanged {
                endPinchZoom()
                return event
            } else {
                return handlePinchZoom(event, reverse: pinchZoomReversed)
            }
        }

        guard event.type == .scrollWheel else {
            return event
        }

        let scrollWheelEventView = ScrollWheelEventView(event)
        let isHorizontal = scrollWheelEventView.deltaYPt == 0 && scrollWheelEventView.deltaXPt != 0
        let modifiers = (isHorizontal ? modifiers.horizontal : modifiers.vertical) ?? .init()

        let actions: [(CGEventFlags.Element, Action?)] = [
            (.maskCommand, modifiers.command),
            (.maskShift, modifiers.shift),
            (.maskAlternate, modifiers.option),
            (.maskControl, modifiers.control)
        ]
        var event = event
        var hasExplicitModifierAction = false
        for case let (flag, action) in actions where event.flags.contains(flag) {
            if let action, action != .auto {
                hasExplicitModifierAction = true
                guard let handledEvent = handleModifierKeyAction(for: event, action: action) else {
                    return nil
                }
                event = handledEvent
                event.flags.remove(flag)
            }
        }
        if isHorizontal, !hasExplicitModifierAction, horizontalAction != .scroll {
            defaultHorizontalPinch = true
            pinchAxis = .horizontal
            pinchZoomReversed = horizontalAction == .pinchZoomReversed
            return handlePinchZoom(event, reverse: pinchZoomReversed)
        }
        return event
    }

    private func handleModifierKeyAction(for event: CGEvent, action: Action) -> CGEvent? {
        let scrollWheelEventView = ScrollWheelEventView(event)

        switch action {
        case .auto, .ignore:
            break
        case .preventDefault:
            return nil
        case .alterOrientation:
            scrollWheelEventView.swapXY()
        case let .changeSpeed(scale: scale):
            scrollWheelEventView.scale(factor: scale.asTruncatedDouble)
        case .zoom, .zoomReversed:
            let scrollWheelEventView = ScrollWheelEventView(event)
            var deltaSignum = scrollWheelEventView.deltaYSignum != 0 ? scrollWheelEventView
                .deltaYSignum : scrollWheelEventView.deltaXSignum
            if action == .zoomReversed {
                deltaSignum *= -1
            }
            if deltaSignum == 0 {
                return event
            }
            guard scrollWheelEventView.momentumPhase == .none else {
                return nil
            }
            let axis: ScrollInput.Axis = scrollWheelEventView.deltaYSignum != 0 ? .vertical : .horizontal
            scrollGesture.claim()
            let restoringModifierFlags = ModifierState.normalize(event.flags)
            if let shortcut = zoomShortcut(deltaSignum > 0) {
                guard scrollThrottle.allowsAction(on: axis, at: monotonicClock()) else {
                    return nil
                }
                try? keySimulator.press(
                    keyCode: shortcut.keyCode,
                    modifierFlags: shortcut.modifierFlags,
                    restoringModifierFlags: restoringModifierFlags,
                    tap: .cgSessionEventTap
                )
            }
            return nil
        case .pinchZoom:
            pinchAxis = scrollWheelEventView.deltaYPt != 0 ? .vertical : .horizontal
            pinchZoomReversed = false
            return handlePinchZoom(event, reverse: false)
        case .pinchZoomReversed:
            pinchAxis = scrollWheelEventView.deltaYPt != 0 ? .vertical : .horizontal
            pinchZoomReversed = true
            return handlePinchZoom(event, reverse: true)
        }

        return event
    }

    private func handlePinchZoom(_ event: CGEvent, reverse: Bool) -> CGEvent? {
        guard event.type == .scrollWheel || event.type == .flagsChanged else {
            return event
        }

        if event.type == .flagsChanged {
            endPinchZoom()
            return event
        }

        if !pinchZoomBegan {
            GestureEvent(zoomSource: nil, phase: .began, magnification: 0)?.send(to: postGestureEvent)
            pinchZoomBegan = true
            os_log("pinch zoom began", log: Self.log, type: .info)
        }

        let scrollWheelEventView = ScrollWheelEventView(event)
        let direction = reverse ? -1.0 : 1.0
        let points = pinchAxis == .horizontal ? scrollWheelEventView.deltaXPt : scrollWheelEventView.deltaYPt
        let magnification = points * 0.005 * direction
        GestureEvent(zoomSource: nil, phase: .changed, magnification: magnification)?.send(to: postGestureEvent)
        os_log("pinch zoom changed: magnification=%f", log: Self.log, type: .info, magnification)

        if defaultHorizontalPinch {
            endTimer?.invalidate()
            endGeneration &+= 1
            let generation = endGeneration
            if scrollWheelEventView.scrollPhase == .cancelled || scrollWheelEventView.momentumPhase == .end {
                endPinchZoom()
            } else {
                endTimer = scheduleEnd(1) { [weak self] in
                    guard let self, self.endGeneration == generation else { return }
                    self.endPinchZoom()
                }
            }
        }
        return nil
    }
}

extension ModifierActionsTransformer: Deactivatable {
    private func endPinchZoom() {
        endGeneration &+= 1
        endTimer?.invalidate()
        endTimer = nil
        defaultHorizontalPinch = false
        guard pinchZoomBegan else { return }
        pinchZoomBegan = false
        pinchZoomReversed = false
        GestureEvent(zoomSource: nil, phase: .ended, magnification: 0)?.send(to: postGestureEvent)
    }

    func deactivate() {
        endPinchZoom()
    }
}
