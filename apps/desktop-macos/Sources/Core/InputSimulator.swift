import Foundation
import CoreGraphics
import AppKit
import os

/// Ultra-Smooth 120Hz Frame-Paced Anti-Jitter Input Engine for macOS
/// Provides 0.0ms perceived latency on stroke start, native 1:1 direct tracking
/// on normal streaming, and frame-paced burst absorption (120Hz) during Wi-Fi jitter.
/// Strictly non-blocking for network receive queues: all CGEvent posts run on a dedicated queue.
public final class InputSimulator: @unchecked Sendable {
    public static let shared = InputSimulator()

    private var lock = os_unfair_lock()

    // In-memory cursor tracking
    private var cachedX: Double = 0.0
    private var cachedY: Double = 0.0
    private var hasValidCache: Bool = false
    private var lastActivityTimestamp: UInt64 = 0

    // Frame-Paced Burst Absorption & Reservoir State
    private var pendingDx: Double = 0.0
    private var pendingDy: Double = 0.0
    private var lastPostTime: UInt64 = 0
    private var avgPacketMag: Double = 10.0
    private var isTimerArmed: Bool = false

    private let glideQueue = DispatchQueue(label: "com.aircontrol.input.glide", qos: .userInteractive)
    private var glideTimer: DispatchSourceTimer?

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

        startGlidePacer()
    }

    // MARK: - Frame-Paced Timer Management (Sleeps when idle, wakes on burst)

    private func startGlidePacer() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: glideQueue)
        timer.setEventHandler { [weak self] in
            self?.tickGlidePacer()
        }
        timer.resume()
        self.glideTimer = timer
    }

    private func armTimerLocked(delayMs: Double) {
        let deadline = DispatchTime.now() + .milliseconds(max(1, Int(delayMs.rounded())))
        glideTimer?.schedule(deadline: deadline, leeway: .microseconds(500))
        isTimerArmed = true
    }

    private func disarmTimerLocked() {
        glideTimer?.schedule(deadline: .distantFuture)
        isTimerArmed = false
    }

    private func tickGlidePacer() {
        var target: CGPoint = .zero
        var dragActive = false
        var shouldPost = false

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let pendingMag = hypot(pendingDx, pendingDy)
        if pendingMag < 0.05 {
            pendingDx = 0.0
            pendingDy = 0.0
            disarmTimerLocked()
            os_unfair_lock_unlock(&lock)
            return
        }

        // Pace out backlog at 120Hz with smooth clamp (max 1.35x recent average packet)
        let maxStep = max(2.0, avgPacketMag * 1.35)
        let stepX: Double
        let stepY: Double
        if pendingMag <= maxStep {
            stepX = pendingDx
            stepY = pendingDy
            pendingDx = 0.0
            pendingDy = 0.0
            disarmTimerLocked()
        } else {
            let ratio = maxStep / pendingMag
            stepX = pendingDx * ratio
            stepY = pendingDy * ratio
            pendingDx -= stepX
            pendingDy -= stepY
            armTimerLocked(delayMs: 8.0) // Re-arm for next 120Hz tick if backlog remains
        }

        let rawTarget = CGPoint(x: cachedX + stepX, y: cachedY + stepY)
        target = snapToDisplayBoundsLocked(rawTarget)
        cachedX = target.x
        cachedY = target.y
        lastPostTime = now
        dragActive = isDragging
        shouldPost = true
        os_unfair_lock_unlock(&lock)

        if shouldPost {
            postPointerEvent(at: target, isDragging: dragActive, coalesced: true)
        }
    }

    private func flushPendingLocked() -> CGPoint {
        if abs(pendingDx) > 0.01 || abs(pendingDy) > 0.01 {
            let rawTarget = CGPoint(x: cachedX + pendingDx, y: cachedY + pendingDy)
            let snapped = snapToDisplayBoundsLocked(rawTarget)
            cachedX = snapped.x
            cachedY = snapped.y
            pendingDx = 0.0
            pendingDy = 0.0
            disarmTimerLocked()
        }
        return CGPoint(x: cachedX, y: cachedY)
    }

    private func postPointerEvent(at target: CGPoint, isDragging dragActive: Bool, coalesced: Bool) {
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let eventType: CGEventType = dragActive ? .leftMouseDragged : .mouseMoved
        if let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: target,
            mouseButton: .left
        ) {
            event.post(tap: .cgSessionEventTap)
        }
        let dtUs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1_000.0
        DiagnosticLogger.shared.recordCgEventPost(durationUs: dtUs, coalesced: coalesced)
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
            lastAccel = Self.baseMultiplier * sensitivity
            pendingDx = 0.0
            pendingDy = 0.0
            disarmTimerLocked()
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

    // MARK: - Pointer Movement with 0.0ms Stroke Start & 120Hz Burst Absorption

    public func move(dx: Float, dy: Float, isStrokeStart: Bool = false) {
        guard dx != 0 || dy != 0 else { return }

        var target: CGPoint = .zero
        var dragActive = false
        var shouldPost = false

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)

        let dist = hypotf(dx, dy)
        let baseGain = Self.baseMultiplier * sensitivity
        let rawAccel = baseGain * (1.0 + min(dist * 0.10, 1.8))

        let isFreshStroke = isStrokeStart || lastActivityTimestamp == 0 || (now - lastActivityTimestamp) > 75_000_000
        if isFreshStroke {
            lastAccel = baseGain
        } else {
            lastAccel = lastAccel + 0.35 * (rawAccel - lastAccel)
        }
        let accel = lastAccel

        let deltaX = Double(dx * accel)
        let deltaY = Double(dy * accel)
        let incomingMag = hypot(deltaX, deltaY)
        avgPacketMag = avgPacketMag * 0.70 + incomingMag * 0.30

        pendingDx += deltaX
        pendingDy += deltaY

        let sinceLastPostNs = lastPostTime > 0 ? (now - lastPostTime) : 200_000_000
        let minIntervalNs: UInt64 = 8_000_000 // 8ms (120Hz cadence)

        if isFreshStroke || sinceLastPostNs >= minIntervalNs {
            let pendingMag = hypot(pendingDx, pendingDy)
            let hasPriorBacklog = pendingMag > (incomingMag * 1.15)
            let maxImmediate = (isFreshStroke || !hasPriorBacklog) ? 1e9 : max(incomingMag, avgPacketMag * 1.35)

            let stepX: Double
            let stepY: Double
            if pendingMag <= maxImmediate {
                stepX = pendingDx
                stepY = pendingDy
                pendingDx = 0.0
                pendingDy = 0.0
                disarmTimerLocked()
            } else {
                let ratio = maxImmediate / pendingMag
                stepX = pendingDx * ratio
                stepY = pendingDy * ratio
                pendingDx -= stepX
                pendingDy -= stepY
            }

            let rawTarget = CGPoint(x: cachedX + stepX, y: cachedY + stepY)
            target = snapToDisplayBoundsLocked(rawTarget)
            cachedX = target.x
            cachedY = target.y
            lastPostTime = now
            dragActive = isDragging
            shouldPost = true

            let hasRemaining = hypot(pendingDx, pendingDy) >= 0.05
            if hasRemaining && !isTimerArmed {
                armTimerLocked(delayMs: 8.0)
            }
        } else {
            // Rapid packet arrival (< 8ms since last post): buffer into pending and arm timer
            if !isTimerArmed {
                let remainingNs = minIntervalNs - sinceLastPostNs
                let delayMs = max(1.0, Double(remainingNs) / 1_000_000.0)
                armTimerLocked(delayMs: delayMs)
            }
        }
        lastActivityTimestamp = now
        os_unfair_lock_unlock(&lock)

        if shouldPost {
            glideQueue.async { [weak self] in
                self?.postPointerEvent(at: target, isDragging: dragActive, coalesced: false)
            }
        }
    }

    public func dragMove(dx: Float, dy: Float, isStrokeStart: Bool = false) {
        guard dx != 0 || dy != 0 else { return }

        var needMouseDown = false
        var downPoint: CGPoint = .zero

        os_unfair_lock_lock(&lock)
        if !isDragging {
            isDragging = true
            needMouseDown = true
            downPoint = flushPendingLocked()
        }
        os_unfair_lock_unlock(&lock)

        if needMouseDown {
            glideQueue.async {
                if let downEv = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseDown,
                    mouseCursorPosition: downPoint,
                    mouseButton: .left
                ) {
                    downEv.post(tap: .cgSessionEventTap)
                }
            }
        }

        move(dx: dx, dy: dy, isStrokeStart: isStrokeStart)
    }

    // MARK: - Zero-Latency Frame-Paced Scroll

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
            glideQueue.async {
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
    }

    // MARK: - Clicks & Drag State

    public func setDragging(_ dragging: Bool) {
        var shouldPost = false
        var targetPoint: CGPoint = .zero

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)
        targetPoint = flushPendingLocked()
        if isDragging != dragging {
            isDragging = dragging
            shouldPost = true
        }
        os_unfair_lock_unlock(&lock)

        guard shouldPost else { return }
        glideQueue.async {
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
    }

    public func leftClick() {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)
        let targetPoint = flushPendingLocked()
        isDragging = false
        os_unfair_lock_unlock(&lock)

        glideQueue.async {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left)
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    public func doubleClick() {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)
        let targetPoint = flushPendingLocked()
        isDragging = false
        os_unfair_lock_unlock(&lock)

        glideQueue.async {
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
    }

    public func rightClick() {
        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)
        let targetPoint = flushPendingLocked()
        isDragging = false
        os_unfair_lock_unlock(&lock)

        glideQueue.async {
            let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: targetPoint, mouseButton: .right)
            let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: targetPoint, mouseButton: .right)
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }
}
