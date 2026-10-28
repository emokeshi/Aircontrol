import Foundation
import CoreGraphics
import AppKit
import os

/// High-Performance macOS Input Engine
/// Implements Remote Mouse's exact reverse-engineered non-linear acceleration & display-clamped event tap
public final class InputSimulator: @unchecked Sendable {
    public static let shared = InputSimulator()

    private var lock = os_unfair_lock()
    private let eventSource: CGEventSource?

    // In-memory cursor tracking (eliminates expensive WindowServer Mach IPC queries)
    private var cachedX: Double = 0.0
    private var cachedY: Double = 0.0
    private var hasValidCache: Bool = false
    private var lastMoveTimestamp: UInt64 = 0

    // Remote Mouse acceleration state
    private var lastAccel: Float = 0.0
    private var isDragging: Bool = false

    // Baseline golden speed multiplier (Remote Mouse discrete speed parameter)
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
        self.eventSource = CGEventSource(stateID: .hidSystemState)

        let savedSens = UserDefaults.standard.double(forKey: "aircontrol_sensitivity")
        self.sensitivity = savedSens > 0.1 ? Float(savedSens) : 1.0

        if UserDefaults.standard.object(forKey: "aircontrol_natural_scroll") != nil {
            self.isNaturalScroll = UserDefaults.standard.bool(forKey: "aircontrol_natural_scroll")
        } else {
            self.isNaturalScroll = true
        }
    }

    // MARK: - Cursor Position Synchronization

    /// Synchronizes internal cached cursor coordinate with macOS WindowServer if idle >= 100ms
    private func syncCursorPositionIfNeeded(now: UInt64) {
        let elapsedNs = lastMoveTimestamp > 0 ? (now - lastMoveTimestamp) : 100_000_000
        // Remote Mouse invalidates cursor cache after 100ms (0x5f5e100 ns)
        if !hasValidCache || elapsedNs >= 100_000_000 {
            if let sysLoc = CGEvent(source: nil)?.location {
                cachedX = sysLoc.x
                cachedY = sysLoc.y
            }
            hasValidCache = true
            lastAccel = 0.0
        }
    }

    // MARK: - Multi-Display Boundary Snapping

    /// Clamps target cursor coordinates within active display bounds
    private func snapToDisplayBounds(_ point: CGPoint) -> CGPoint {
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

    // MARK: - Cursor Movement & Dragging (Remote Mouse Reverse-Engineered Pipeline)

    public func move(dx: Float, dy: Float) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard dx != 0 || dy != 0 else { return }

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsedNs = lastMoveTimestamp > 0 ? (now - lastMoveTimestamp) : 16_666_667
        syncCursorPositionIfNeeded(now: now)

        var moveDx = dx
        var moveDy = dy

        // Calculate dt in seconds
        let rawDt = Float(elapsedNs) / 1_000_000_000.0
        let dt: Float
        if rawDt >= 0.002 && rawDt <= 0.05 {
            dt = rawDt
        } else {
            // Clamp out-of-bounds network bursts/lags to standard 60Hz frame time
            dt = 1.0 / 60.0
        }

        // Remote Mouse dynamic acceleration model:
        // dist = hypot(dx, dy)
        // factor = (dist * (1/60) / dt) / effective_speed
        // accel = 1.0 + factor
        let dist = hypotf(moveDx, moveDy)
        let effectiveSpeed = max(0.5, Self.baseMultiplier * sensitivity)
        let factor = (dist * (1.0 / 60.0) / dt) / effectiveSpeed
        var accel = 1.0 + factor

        // Remote Mouse EMA smoothing on acceleration (40ms time constant)
        if lastAccel > 0.0 && rawDt <= 0.1 {
            let alpha = min(1.0, dt / 0.04)
            accel = lastAccel + alpha * (accel - lastAccel)
        }
        lastAccel = accel

        moveDx *= accel
        moveDy *= accel

        let rawTarget = CGPoint(x: cachedX + Double(moveDx), y: cachedY + Double(moveDy))
        let target = snapToDisplayBounds(rawTarget)

        cachedX = target.x
        cachedY = target.y
        lastMoveTimestamp = now

        let eventType: CGEventType = isDragging ? .leftMouseDragged : .mouseMoved

        // Direct session event tap injection (never set deltaX/deltaY to prevent double-accumulation stutter)
        if let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: target,
            mouseButton: .left
        ) {
            event.post(tap: .cgSessionEventTap)
        }
    }

    public func setDragging(_ dragging: Bool) {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeeded(now: now)
        isDragging = dragging
        let targetPoint = CGPoint(x: cachedX, y: cachedY)
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

    // MARK: - Discrete Clicks (Session Event Tap with Cursor Sync)

    public func leftClick() {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeeded(now: now)
        let targetPoint = CGPoint(x: cachedX, y: cachedY)
        os_unfair_lock_unlock(&lock)

        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    public func doubleClick() {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeeded(now: now)
        let targetPoint = CGPoint(x: cachedX, y: cachedY)
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
        syncCursorPositionIfNeeded(now: now)
        let targetPoint = CGPoint(x: cachedX, y: cachedY)
        os_unfair_lock_unlock(&lock)

        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: targetPoint, mouseButton: .right)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: targetPoint, mouseButton: .right)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    // MARK: - Smooth Pixel Scrolling (Session Event Tap)

    public func scroll(dx: Float, dy: Float) {
        let scrollMultiplier: Float = isNaturalScroll ? 1.0 : -1.0
        let wheel1 = Int32(dy * scrollMultiplier * 2.0)
        let wheel2 = Int32(dx * scrollMultiplier * 2.0)

        let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        )
        scrollEvent?.post(tap: .cgSessionEventTap)
    }
}
