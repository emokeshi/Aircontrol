import Foundation
import CoreGraphics
import AppKit
import os

/// High-Performance macOS Input Engine
/// Uses a 120Hz frame-paced producer-consumer interpolator to eliminate Wi-Fi packet burst jitter
public final class InputSimulator: @unchecked Sendable {
    public static let shared = InputSimulator()

    private var lock = os_unfair_lock()
    private let renderQueue = DispatchQueue(label: "com.aircontrol.input.render", qos: .userInteractive)
    private var frameTimer: DispatchSourceTimer?
    private var isTimerRunning: Bool = false
    private var idleFrames: Int = 0

    // In-memory cursor tracking
    private var cachedX: Double = 0.0
    private var cachedY: Double = 0.0
    private var hasValidCache: Bool = false
    private var lastActivityTimestamp: UInt64 = 0

    // Sub-frame interpolation accumulators (decouples network receipt from CGEventPost)
    private var pendingDx: Double = 0.0
    private var pendingDy: Double = 0.0
    private var pendingScrollX: Double = 0.0
    private var pendingScrollY: Double = 0.0

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

        setupFrameTimer()
    }

    // MARK: - 120Hz Frame-Paced Consumer Loop

    private func setupFrameTimer() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
        // 120Hz (8.333ms) cadence with 0.5ms leeway
        timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            self?.renderTick()
        }
        self.frameTimer = timer
    }

    private func ensureTimerActiveLocked() {
        idleFrames = 0
        if !isTimerRunning {
            isTimerRunning = true
            frameTimer?.resume()
        }
    }

    private func renderTick() {
        var postMovePoint: CGPoint? = nil
        var currentDragState: Bool = false
        var scrollWheel1: Int32 = 0
        var scrollWheel2: Int32 = 0

        os_unfair_lock_lock(&lock)

        let remDist = hypot(pendingDx, pendingDy)
        let remScroll = hypot(pendingScrollX, pendingScrollY)

        if remDist < 0.04 && remScroll < 0.2 {
            pendingDx = 0.0
            pendingDy = 0.0
            pendingScrollX = 0.0
            pendingScrollY = 0.0
            idleFrames += 1
            // Pause timer after ~100ms of inactivity for 0% idle CPU usage
            if idleFrames >= 12 && isTimerRunning {
                isTimerRunning = false
                frameTimer?.suspend()
            }
            os_unfair_lock_unlock(&lock)
            return
        }

        idleFrames = 0

        // 1. Drain pointer delta smoothly (68% per 120Hz frame bridges Wi-Fi micro-dropouts)
        if remDist >= 0.04 {
            let drainFactor: Double = remDist < 0.5 ? 1.0 : 0.68
            let stepX = pendingDx * drainFactor
            let stepY = pendingDy * drainFactor
            pendingDx -= stepX
            pendingDy -= stepY

            let rawTarget = CGPoint(x: cachedX + stepX, y: cachedY + stepY)
            let clamped = snapToDisplayBoundsLocked(rawTarget)
            cachedX = clamped.x
            cachedY = clamped.y
            postMovePoint = clamped
            currentDragState = isDragging
        }

        // 2. Drain scroll delta smoothly
        if remScroll >= 0.2 {
            let scrollDrain: Double = remScroll < 1.0 ? 1.0 : 0.65
            let stepSX = pendingScrollX * scrollDrain
            let stepSY = pendingScrollY * scrollDrain
            pendingScrollX -= stepSX
            pendingScrollY -= stepSY

            scrollWheel1 = Int32(stepSY.rounded())
            scrollWheel2 = Int32(stepSX.rounded())
        }

        os_unfair_lock_unlock(&lock)

        // Post at most 1 mouse event and 1 scroll event per 120Hz display frame
        if let target = postMovePoint {
            let eventType: CGEventType = currentDragState ? .leftMouseDragged : .mouseMoved
            if let event = CGEvent(
                mouseEventSource: nil,
                mouseType: eventType,
                mouseCursorPosition: target,
                mouseButton: .left
            ) {
                event.post(tap: .cgSessionEventTap)
            }
        }

        if scrollWheel1 != 0 || scrollWheel2 != 0 {
            if let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: scrollWheel1,
                wheel2: scrollWheel2,
                wheel3: 0
            ) {
                scrollEvent.post(tap: .cgSessionEventTap)
            }
        }
    }

    // MARK: - Cursor Synchronization & Display Bounds

    private func syncCursorPositionIfNeededLocked(now: UInt64) {
        let elapsedNs = lastActivityTimestamp > 0 ? (now - lastActivityTimestamp) : 150_000_000
        if !hasValidCache || elapsedNs >= 150_000_000 {
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
        if abs(pendingDx) > 0.01 || abs(pendingDy) > 0.01 {
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

    // MARK: - Producer API (Called from Network Thread)

    public func move(dx: Float, dy: Float) {
        guard dx != 0 || dy != 0 else { return }

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)

        // Jitter-immune non-linear acceleration based on touch sample magnitude
        let dist = hypotf(dx, dy)
        let baseGain = Self.baseMultiplier * sensitivity
        let rawAccel = baseGain * (1.0 + min(dist * 0.12, 2.2))

        // Smooth acceleration transitions (EMA alpha = 0.35)
        let accel = lastAccel + 0.35 * (rawAccel - lastAccel)
        lastAccel = accel

        pendingDx += Double(dx * accel)
        pendingDy += Double(dy * accel)

        ensureTimerActiveLocked()
        os_unfair_lock_unlock(&lock)
    }

    public func scroll(dx: Float, dy: Float) {
        guard dx != 0 || dy != 0 else { return }

        let scrollMultiplier: Float = isNaturalScroll ? 1.0 : -1.0
        os_unfair_lock_lock(&lock)
        pendingScrollX += Double(dx * scrollMultiplier * 2.2)
        pendingScrollY += Double(dy * scrollMultiplier * 2.2)
        ensureTimerActiveLocked()
        os_unfair_lock_unlock(&lock)
    }

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
