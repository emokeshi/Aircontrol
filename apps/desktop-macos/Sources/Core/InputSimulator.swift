import Foundation
import CoreGraphics
import AppKit
import os

/// Ultra-Smooth Anti-Jitter Frame-Paced Input Engine for macOS
/// Absorbs Wi-Fi packet jitter and micro-bursts with 240Hz frame-paced glide interpolation
/// and dead-reckoning extrapolation during packet gaps, with zero lag on stroke start.
public final class InputSimulator: @unchecked Sendable {
    public static let shared = InputSimulator()

    private var lock = os_unfair_lock()

    // In-memory cursor tracking
    private var cachedX: Double = 0.0
    private var cachedY: Double = 0.0
    private var hasValidCache: Bool = false
    private var lastActivityTimestamp: UInt64 = 0

    // 240Hz Anti-Jitter Glide Reservoir & Velocity State
    private var pendingDx: Double = 0.0
    private var pendingDy: Double = 0.0
    private var borrowedDx: Double = 0.0
    private var borrowedDy: Double = 0.0
    private var velX: Double = 0.0 // in pixels / ms
    private var velY: Double = 0.0 // in pixels / ms
    private var lastPacketTimestamp: UInt64 = 0
    private var lastTickTimestamp: UInt64 = 0
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

        startGlideInterpolator()
    }

    // MARK: - 240Hz Anti-Jitter Frame-Paced Interpolator & Dead-Reckoning

    private func startGlideInterpolator() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: glideQueue)
        // 240Hz pacing: fires every 4.16ms (240fps) to synchronize with 60Hz and 120Hz displays
        timer.schedule(deadline: .now() + .milliseconds(4), repeating: .nanoseconds(4_166_667), leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in
            self?.tickGlideInterpolator()
        }
        timer.resume()
        self.glideTimer = timer
    }

    private func tickGlideInterpolator() {
        var target: CGPoint = .zero
        var dragActive = false
        var shouldPost = false

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let dtMs: Double
        if lastTickTimestamp > 0 {
            dtMs = min(max(Double(now - lastTickTimestamp) / 1_000_000.0, 1.5), 12.0)
        } else {
            dtMs = 4.16
        }
        lastTickTimestamp = now

        let sinceLastPacketMs = lastPacketTimestamp > 0 ? (Double(now - lastPacketTimestamp) / 1_000_000.0) : 1000.0
        let pendingMag = hypot(pendingDx, pendingDy)

        var stepX: Double = 0.0
        var stepY: Double = 0.0

        if pendingMag > 0.05 {
            // Case A: Discharging pending displacement reservoir
            if pendingMag < 0.6 {
                // Nearly finished or stopping: drain 100% to snap crisp stop
                stepX = pendingDx
                stepY = pendingDy
                pendingDx = 0.0
                pendingDy = 0.0
            } else {
                // Active glide: drain ~40% per 4ms tick (smoothly distributes over 12-16ms)
                let drainRatio = min(0.60, max(0.35, 1.0 / (16.0 / dtMs)))
                stepX = pendingDx * drainRatio
                stepY = pendingDy * drainRatio
                pendingDx -= stepX
                pendingDy -= stepY
            }
        } else if sinceLastPacketMs < 35.0 && (abs(velX) > 0.02 || abs(velY) > 0.02) {
            // Case B: Wi-Fi packet stall (16ms..35ms gap)!
            // Dead-reckoning: maintain cursor motion at decayed hand velocity so display frame never freezes.
            let decay = max(0.0, 1.0 - (sinceLastPacketMs - 16.0) / 19.0)
            stepX = velX * dtMs * decay * 0.50
            stepY = velY * dtMs * decay * 0.50
            // Record borrowed displacement so when delayed packets arrive, no double-displacement jump occurs
            borrowedDx += stepX
            borrowedDy += stepY
        } else {
            // Case C: Idle / Stationary
            velX = 0.0
            velY = 0.0
            pendingDx = 0.0
            pendingDy = 0.0
            borrowedDx = 0.0
            borrowedDy = 0.0
        }

        let stepMag = hypot(stepX, stepY)
        if stepMag > 0.02 {
            let rawTarget = CGPoint(x: cachedX + stepX, y: cachedY + stepY)
            target = snapToDisplayBoundsLocked(rawTarget)
            cachedX = target.x
            cachedY = target.y
            dragActive = isDragging
            shouldPost = true
        }
        os_unfair_lock_unlock(&lock)

        guard shouldPost else { return }
        postPointerEvent(at: target, isDragging: dragActive, coalesced: true)
    }

    private func flushPendingLocked() -> CGPoint {
        if abs(pendingDx) > 0.01 || abs(pendingDy) > 0.01 {
            let rawTarget = CGPoint(x: cachedX + pendingDx, y: cachedY + pendingDy)
            let snapped = snapToDisplayBoundsLocked(rawTarget)
            cachedX = snapped.x
            cachedY = snapped.y
            pendingDx = 0.0
            pendingDy = 0.0
            velX = 0.0
            velY = 0.0
            borrowedDx = 0.0
            borrowedDy = 0.0
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
            velX = 0.0
            velY = 0.0
            borrowedDx = 0.0
            borrowedDy = 0.0
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

    // MARK: - Pointer Movement with Zero-Latency Stroke Start & 240Hz Anti-Jitter

    public func move(dx: Float, dy: Float, isStrokeStart: Bool = false) {
        guard dx != 0 || dy != 0 else { return }

        var immediateTarget: CGPoint = .zero
        var shouldPostImmediate = false
        var dragActive = false

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)

        let dist = hypotf(dx, dy)
        let baseGain = Self.baseMultiplier * sensitivity
        let rawAccel = baseGain * (1.0 + min(dist * 0.10, 1.8))

        let isFreshStroke = isStrokeStart || lastPacketTimestamp == 0 || (now - lastPacketTimestamp) > 40_000_000
        if isFreshStroke {
            lastAccel = baseGain
        } else {
            lastAccel = lastAccel + 0.35 * (rawAccel - lastAccel)
        }
        let accel = lastAccel

        let deltaX = Double(dx * accel)
        let deltaY = Double(dy * accel)

        let dtPacket = lastPacketTimestamp > 0 ? min(Double(now - lastPacketTimestamp) / 1_000_000.0, 35.0) : 16.67
        if dtPacket > 1.0 {
            let vx = deltaX / dtPacket
            let vy = deltaY / dtPacket
            if isFreshStroke {
                velX = vx
                velY = vy
            } else {
                velX = velX * 0.60 + vx * 0.40
                velY = velY * 0.60 + vy * 0.40
            }
        }

        if isFreshStroke {
            // Immediate response on stroke start: step 75% instantly for 0.0ms perceived latency
            let stepX = deltaX * 0.75
            let stepY = deltaY * 0.75
            pendingDx = deltaX - stepX
            pendingDy = deltaY - stepY
            borrowedDx = 0.0
            borrowedDy = 0.0

            let rawTarget = CGPoint(x: cachedX + stepX, y: cachedY + stepY)
            immediateTarget = snapToDisplayBoundsLocked(rawTarget)
            cachedX = immediateTarget.x
            cachedY = immediateTarget.y
            dragActive = isDragging
            shouldPostImmediate = true
        } else {
            var finalDeltaX = deltaX
            var finalDeltaY = deltaY
            // Deduct extrapolated movement already rendered during packet stall to avoid jumps
            if borrowedDx != 0.0 {
                if (finalDeltaX > 0 && borrowedDx > 0) || (finalDeltaX < 0 && borrowedDx < 0) {
                    let absorb = (finalDeltaX > 0) ? min(finalDeltaX, borrowedDx) : max(finalDeltaX, borrowedDx)
                    finalDeltaX -= absorb
                    borrowedDx -= absorb
                } else {
                    borrowedDx = 0.0
                }
            }
            if borrowedDy != 0.0 {
                if (finalDeltaY > 0 && borrowedDy > 0) || (finalDeltaY < 0 && borrowedDy < 0) {
                    let absorb = (finalDeltaY > 0) ? min(finalDeltaY, borrowedDy) : max(finalDeltaY, borrowedDy)
                    finalDeltaY -= absorb
                    borrowedDy -= absorb
                } else {
                    borrowedDy = 0.0
                }
            }
            pendingDx += finalDeltaX
            pendingDy += finalDeltaY
        }

        lastPacketTimestamp = now
        os_unfair_lock_unlock(&lock)

        if shouldPostImmediate {
            postPointerEvent(at: immediateTarget, isDragging: dragActive, coalesced: false)
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
            if let downEv = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: downPoint,
                mouseButton: .left
            ) {
                downEv.post(tap: .cgSessionEventTap)
            }
        }

        move(dx: dx, dy: dy, isStrokeStart: isStrokeStart)
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
        let targetPoint = flushPendingLocked()
        isDragging = false
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
        let targetPoint = flushPendingLocked()
        isDragging = false
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
        let targetPoint = flushPendingLocked()
        isDragging = false
        os_unfair_lock_unlock(&lock)

        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: targetPoint, mouseButton: .right)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: targetPoint, mouseButton: .right)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
