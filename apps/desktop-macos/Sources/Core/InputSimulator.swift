import Foundation
import CoreGraphics
import AppKit
import os

/// Ultra-Low-Latency Direct Input Engine for macOS
/// Executes CGEventPost immediately with 0.0ms artificial buffering on normal 60Hz/120Hz frames,
/// while coalescing sub-2ms Wi-Fi micro-bursts to protect WindowServer.
public final class InputSimulator: @unchecked Sendable {
    public static let shared = InputSimulator()

    private var lock = os_unfair_lock()
    private let flushQueue = DispatchQueue(label: "com.aircontrol.input.flush", qos: .userInteractive)

    // In-memory cursor tracking
    private var cachedX: Double = 0.0
    private var cachedY: Double = 0.0
    private var hasValidCache: Bool = false
    private var lastActivityTimestamp: UInt64 = 0

    // Micro-burst coalescing (< 2.0ms window)
    private var lastMovePostNs: UInt64 = 0
    private var pendingDx: Double = 0.0
    private var pendingDy: Double = 0.0
    private var moveFlushScheduled: Bool = false

    private var lastScrollPostNs: UInt64 = 0
    private var pendingScrollX: Double = 0.0
    private var pendingScrollY: Double = 0.0
    private var scrollFlushScheduled: Bool = false

    // Acceleration smoothing state
    private var lastAccel: Float = 1.0
    private var isDragging: Bool = false

    // Baseline golden speed multiplier (1.8x default)
    public static let baseMultiplier: Float = 1.8

    public var sensitivity: Float {
        didSet {
            UserDefaults.standard.set(Double(sensitivity), forKey: "aircontrol_sensitivity")
        }
    }

    public var isNaturalScroll: Bool {
        didSet {
            UserDefaults.standard.set(isNaturalScroll, forKey: "aircontrol_natural_scroll")
        }
    }

    private init() {
        let savedSens = UserDefaults.standard.double(forKey: "aircontrol_sensitivity")
        self.sensitivity = savedSens > 0.1 ? Float(savedSens) : 1.0

        if UserDefaults.standard.object(forKey: "aircontrol_natural_scroll") != nil {
            self.isNaturalScroll = UserDefaults.standard.bool(forKey: "aircontrol_natural_scroll")
        } else {
            self.isNaturalScroll = true
        }
    }

    // MARK: - Cursor Synchronization & Display Bounds

    private func syncCursorPositionIfNeededLocked(now: UInt64) {
        let elapsedNs = lastActivityTimestamp > 0 ? (now - lastActivityTimestamp) : 180_000_000
        if !hasValidCache || elapsedNs >= 180_000_000 {
            if let sysLoc = CGEvent(source: nil)?.location {
                cachedX = sysLoc.x
                cachedY = sysLoc.y
            }
            hasValidCache = true
            lastAccel = 1.0
        }
        lastActivityTimestamp = now
    }

    private func flushPendingMovementLocked() -> CGPoint {
        if abs(pendingDx) > 0.001 || abs(pendingDy) > 0.001 {
            let rawTarget = CGPoint(x: cachedX + pendingDx, y: cachedY + pendingDy)
            let clamped = snapToDisplayBoundsLocked(rawTarget)
            cachedX = clamped.x
            cachedY = clamped.y
            pendingDx = 0.0
            pendingDy = 0.0
        }
        return CGPoint(x: cachedX, y: cachedY)
    }

    private func snapToDisplayBoundsLocked(_ point: CGPoint) -> CGPoint {
        var matchedDisplay: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let status = CGGetDisplaysWithPoint(point, 1, &matchedDisplay, &count)
        if status == .success && count > 0 {
            return point
        }

        var currentDisplay: CGDirectDisplayID = 0
        var currentCount: UInt32 = 0
        let currentPoint = CGPoint(x: cachedX, y: cachedY)
        CGGetDisplaysWithPoint(currentPoint, 1, &currentDisplay, &currentCount)

        let activeBounds: CGRect
        if currentCount > 0 {
            activeBounds = CGDisplayBounds(currentDisplay)
        } else {
            activeBounds = CGDisplayBounds(CGMainDisplayID())
        }

        let clampedX = max(activeBounds.minX, min(activeBounds.maxX - 1.0, point.x))
        let clampedY = max(activeBounds.minY, min(activeBounds.maxY - 1.0, point.y))
        return CGPoint(x: clampedX, y: clampedY)
    }

    // MARK: - Zero-Latency Pointer Movement with Sub-2ms Burst Coalescing

    public func move(dx: Float, dy: Float) {
        guard dx != 0 || dy != 0 else { return }

        var immediateTarget: CGPoint? = nil
        var dragFlag: Bool = false
        var shouldScheduleFlush: Bool = false

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)

        // Jitter-immune non-linear acceleration based solely on touch delta magnitude
        let dist = hypotf(dx, dy)
        let baseGain = Self.baseMultiplier * sensitivity
        let rawAccel = baseGain * (1.0 + min(dist * 0.10, 1.8))

        // Gentle EMA smoothing on the gain factor only (never delays position)
        let accel = lastAccel + 0.45 * (rawAccel - lastAccel)
        lastAccel = accel

        pendingDx += Double(dx * accel)
        pendingDy += Double(dy * accel)

        // If >= 2.0ms since last post, apply 100% of delta immediately (0.0ms lag)
        if (now - lastMovePostNs) >= 2_000_000 {
            immediateTarget = flushPendingMovementLocked()
            dragFlag = isDragging
            lastMovePostNs = now
        } else if !moveFlushScheduled {
            moveFlushScheduled = true
            shouldScheduleFlush = true
        }
        os_unfair_lock_unlock(&lock)

        if let target = immediateTarget {
            postMouseEvent(at: target, dragging: dragFlag)
        } else {
            DiagnosticLogger.shared.recordCgEventPost(durationUs: 0, coalesced: true)
            if shouldScheduleFlush {
                flushQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                    self?.flushCoalescedMove()
                }
            }
        }
    }

    private func flushCoalescedMove() {
        var target: CGPoint? = nil
        var dragFlag: Bool = false

        os_unfair_lock_lock(&lock)
        moveFlushScheduled = false
        if abs(pendingDx) > 0.001 || abs(pendingDy) > 0.001 {
            target = flushPendingMovementLocked()
            dragFlag = isDragging
            lastMovePostNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        }
        os_unfair_lock_unlock(&lock)

        if let pt = target {
            postMouseEvent(at: pt, dragging: dragFlag)
        }
    }

    private func postMouseEvent(at target: CGPoint, dragging: Bool) {
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let eventType: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        if let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: target,
            mouseButton: .left
        ) {
            event.post(tap: .cgSessionEventTap)
        }
        let dtUs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1_000.0
        DiagnosticLogger.shared.recordCgEventPost(durationUs: dtUs, coalesced: false)
    }

    // MARK: - Zero-Latency Scroll with Sub-3ms Burst Coalescing

    public func scroll(dx: Float, dy: Float) {
        guard dx != 0 || dy != 0 else { return }

        let scrollMultiplier: Float = isNaturalScroll ? 1.0 : -1.0
        var immediateW1: Int32 = 0
        var immediateW2: Int32 = 0
        var shouldSchedule: Bool = false

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        pendingScrollX += Double(dx * scrollMultiplier * 2.2)
        pendingScrollY += Double(dy * scrollMultiplier * 2.2)

        if (now - lastScrollPostNs) >= 3_000_000 {
            immediateW1 = Int32(pendingScrollY.rounded())
            immediateW2 = Int32(pendingScrollX.rounded())
            pendingScrollY -= Double(immediateW1)
            pendingScrollX -= Double(immediateW2)
            lastScrollPostNs = now
        } else if !scrollFlushScheduled {
            scrollFlushScheduled = true
            shouldSchedule = true
        }
        os_unfair_lock_unlock(&lock)

        if immediateW1 != 0 || immediateW2 != 0 {
            postScrollEvent(w1: immediateW1, w2: immediateW2)
        } else if shouldSchedule {
            flushQueue.asyncAfter(deadline: .now() + .milliseconds(3)) { [weak self] in
                self?.flushCoalescedScroll()
            }
        }
    }

    private func flushCoalescedScroll() {
        var w1: Int32 = 0
        var w2: Int32 = 0

        os_unfair_lock_lock(&lock)
        scrollFlushScheduled = false
        w1 = Int32(pendingScrollY.rounded())
        w2 = Int32(pendingScrollX.rounded())
        pendingScrollY -= Double(w1)
        pendingScrollX -= Double(w2)
        lastScrollPostNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        os_unfair_lock_unlock(&lock)

        if w1 != 0 || w2 != 0 {
            postScrollEvent(w1: w1, w2: w2)
        }
    }

    private func postScrollEvent(w1: Int32, w2: Int32) {
        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: w1,
            wheel2: w2,
            wheel3: 0
        ) {
            scrollEvent.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Clicks & Drag State

    public func setDragging(_ dragging: Bool) {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)
        let targetPoint = flushPendingMovementLocked()
        isDragging = dragging
        os_unfair_lock_unlock(&lock)

        let eventType: CGEventType = dragging ? .leftMouseDown : .leftMouseUp
        if let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: targetPoint,
            mouseButton: .left
        ) {
            event.post(tap: .cgSessionEventTap)
        }
    }

    public func leftClick() {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)
        let targetPoint = flushPendingMovementLocked()
        os_unfair_lock_unlock(&lock)

        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    public func doubleClick() {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)
        let targetPoint = flushPendingMovementLocked()
        os_unfair_lock_unlock(&lock)

        let down1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left)
        let up1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left)
        let down2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left)
        down2?.setIntegerValueField(.mouseEventClickState, value: 2)
        let up2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left)
        up2?.setIntegerValueField(.mouseEventClickState, value: 2)

        down1?.post(tap: .cgSessionEventTap)
        up1?.post(tap: .cgSessionEventTap)
        down2?.post(tap: .cgSessionEventTap)
        up2?.post(tap: .cgSessionEventTap)
    }

    public func rightClick() {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)
        let targetPoint = flushPendingMovementLocked()
        os_unfair_lock_unlock(&lock)

        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: targetPoint, mouseButton: .right)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: targetPoint, mouseButton: .right)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
