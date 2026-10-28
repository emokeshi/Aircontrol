import Foundation
import CoreGraphics
import AppKit
import os

/// Ultra-Low-Latency Direct Input Engine for macOS
/// Executes CGEventPost synchronously in ~55 microseconds with 0.0ms artificial timer delay.
public final class InputSimulator: @unchecked Sendable {
    public static let shared = InputSimulator()

    private var lock = os_unfair_lock()

    // In-memory cursor tracking
    private var cachedX: Double = 0.0
    private var cachedY: Double = 0.0
    private var hasValidCache: Bool = false
    private var lastActivityTimestamp: UInt64 = 0

    // Sub-pixel scroll remainder tracking
    private var scrollRemX: Double = 0.0
    private var scrollRemY: Double = 0.0

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
        let elapsedNs = lastActivityTimestamp > 0 ? (now - lastActivityTimestamp) : 200_000_000
        if !hasValidCache || elapsedNs >= 200_000_000 {
            if let sysLoc = CGEvent(source: nil)?.location {
                cachedX = sysLoc.x
                cachedY = sysLoc.y
            }
            hasValidCache = true
            lastAccel = 1.0
        }
        lastActivityTimestamp = now
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

    // MARK: - Zero-Latency Direct Pointer Movement

    public func move(dx: Float, dy: Float) {
        guard dx != 0 || dy != 0 else { return }

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)

        // Jitter-immune non-linear acceleration based solely on touch delta magnitude
        let dist = hypotf(dx, dy)
        let baseGain = Self.baseMultiplier * sensitivity
        let rawAccel = baseGain * (1.0 + min(dist * 0.10, 1.8))

        let accel = lastAccel + 0.45 * (rawAccel - lastAccel)
        lastAccel = accel

        let rawTarget = CGPoint(x: cachedX + Double(dx * accel), y: cachedY + Double(dy * accel))
        let target = snapToDisplayBoundsLocked(rawTarget)
        cachedX = target.x
        cachedY = target.y
        let dragFlag = isDragging
        os_unfair_lock_unlock(&lock)

        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let eventType: CGEventType = dragFlag ? .leftMouseDragged : .mouseMoved
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

    // MARK: - Zero-Latency Scroll

    public func scroll(dx: Float, dy: Float) {
        guard dx != 0 || dy != 0 else { return }

        let scrollMultiplier: Float = isNaturalScroll ? 1.0 : -1.0
        os_unfair_lock_lock(&lock)
        scrollRemX += Double(dx * scrollMultiplier * 2.2)
        scrollRemY += Double(dy * scrollMultiplier * 2.2)
        let w1 = Int32(scrollRemY.rounded())
        let w2 = Int32(scrollRemX.rounded())
        scrollRemY -= Double(w1)
        scrollRemX -= Double(w2)
        os_unfair_lock_unlock(&lock)

        if w1 != 0 || w2 != 0 {
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
    }

    // MARK: - Clicks & Drag State

    public func setDragging(_ dragging: Bool) {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)
        let targetPoint = CGPoint(x: cachedX, y: cachedY)
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
        syncCursorPositionIfNeededLocked(now: now)
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
        syncCursorPositionIfNeededLocked(now: now)
        let targetPoint = CGPoint(x: cachedX, y: cachedY)
        os_unfair_lock_unlock(&lock)

        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: targetPoint, mouseButton: .right)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: targetPoint, mouseButton: .right)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
