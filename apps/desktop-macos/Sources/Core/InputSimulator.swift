import Foundation
import CoreGraphics
import AppKit
import os

/// Ultra-Smooth 250Hz Hybrid Direct + Anti-Jitter Glide Input Engine for macOS
/// - Immediate 0.0ms response on normal packet arrival
/// - Absorbs 802.11 Wi-Fi packet micro-bursts into a 250Hz (4ms) sub-frame interpolator so the cursor never teleports or stutters
public final class InputSimulator: @unchecked Sendable {
    public static let shared = InputSimulator()

    private var lock = os_unfair_lock()

    // In-memory cursor tracking
    private var cachedX: Double = 0.0
    private var cachedY: Double = 0.0
    private var hasValidCache: Bool = false
    private var lastActivityTimestamp: UInt64 = 0
    private var lastPostTimestamp: UInt64 = 0

    // Sub-frame 250Hz Wi-Fi anti-jitter glide reservoir
    private var pendingDx: Double = 0.0
    private var pendingDy: Double = 0.0
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

    private func startGlideInterpolator() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: glideQueue)
        timer.schedule(deadline: .now() + .milliseconds(4), repeating: .milliseconds(4), leeway: .microseconds(500))
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
        let mag = hypot(pendingDx, pendingDy)
        if mag >= 0.12 {
            // Drain 48% of pending displacement every 4ms (250Hz), or 100% if under 0.6px
            let ratio = mag < 0.6 ? 1.0 : 0.48
            let stepX = pendingDx * ratio
            let stepY = pendingDy * ratio
            pendingDx -= stepX
            pendingDy -= stepY

            let rawTarget = CGPoint(x: cachedX + stepX, y: cachedY + stepY)
            target = snapToDisplayBoundsLocked(rawTarget)
            cachedX = target.x
            cachedY = target.y
            lastPostTimestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            dragActive = isDragging
            shouldPost = true
        } else {
            pendingDx = 0.0
            pendingDy = 0.0
        }
        os_unfair_lock_unlock(&lock)

        guard shouldPost else { return }
        postPointerEvent(at: target, isDragging: dragActive, coalesced: true)
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
        let elapsedNs = lastActivityTimestamp > 0 ? (now - lastActivityTimestamp) : 250_000_000
        if !hasValidCache || elapsedNs >= 250_000_000 {
            if let sysLoc = CGEvent(source: nil)?.location {
                cachedX = sysLoc.x
                cachedY = sysLoc.y
            }
            pendingDx = 0.0
            pendingDy = 0.0
            hasValidCache = true
            lastAccel = 1.0
        }
        lastActivityTimestamp = now
    }

    private func flushPendingLocked() -> CGPoint {
        if abs(pendingDx) > 0.01 || abs(pendingDy) > 0.01 {
            let rawTarget = CGPoint(x: cachedX + pendingDx, y: cachedY + pendingDy)
            let snapped = snapToDisplayBoundsLocked(rawTarget)
            cachedX = snapped.x
            cachedY = snapped.y
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

    // MARK: - Hybrid Immediate + 250Hz Anti-Jitter Pointer Movement (0x01)

    public func move(dx: Float, dy: Float) {
        guard dx != 0 || dy != 0 else { return }

        var immediateTarget: CGPoint = .zero
        var dragActive = false
        var shouldPostImmediate = false

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)

        let dist = hypotf(dx, dy)
        let baseGain = Self.baseMultiplier * sensitivity
        let rawAccel = baseGain * (1.0 + min(dist * 0.08, 1.5))
        let accel = lastAccel + 0.35 * (rawAccel - lastAccel)
        lastAccel = accel

        pendingDx += Double(dx * accel)
        pendingDy += Double(dy * accel)

        // If >= 6ms has elapsed since the last cursor post, immediately step 60% for 0.0ms latency
        // and let the 250Hz (4ms) timer smoothly interpolate the remaining 40%.
        // If < 6ms has elapsed (Wi-Fi packet micro-burst!), absorb into pendingDx/pendingDy so the 250Hz timer plays it out smoothly without teleporting!
        let sinceLastPostNs = lastPostTimestamp > 0 ? (now - lastPostTimestamp) : 20_000_000
        if sinceLastPostNs >= 6_000_000 {
            let stepX = pendingDx * 0.60
            let stepY = pendingDy * 0.60
            pendingDx -= stepX
            pendingDy -= stepY

            let rawTarget = CGPoint(x: cachedX + stepX, y: cachedY + stepY)
            immediateTarget = snapToDisplayBoundsLocked(rawTarget)
            cachedX = immediateTarget.x
            cachedY = immediateTarget.y
            lastPostTimestamp = now
            dragActive = isDragging
            shouldPostImmediate = true
        }
        os_unfair_lock_unlock(&lock)

        if shouldPostImmediate {
            postPointerEvent(at: immediateTarget, isDragging: dragActive, coalesced: false)
        }
    }

    // MARK: - Explicit Drag Movement (0x03: Posts leftMouseDown only once, then leftMouseDragged)

    public func dragMove(dx: Float, dy: Float) {
        guard dx != 0 || dy != 0 else { return }

        var needMouseDown = false
        var downPoint: CGPoint = .zero
        var immediateTarget: CGPoint = .zero
        var shouldPostImmediate = false

        os_unfair_lock_lock(&lock)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        syncCursorPositionIfNeededLocked(now: now)

        if !isDragging {
            isDragging = true
            needMouseDown = true
            downPoint = flushPendingLocked()
        }

        let dist = hypotf(dx, dy)
        let baseGain = Self.baseMultiplier * sensitivity
        let rawAccel = baseGain * (1.0 + min(dist * 0.08, 1.5))
        let accel = lastAccel + 0.35 * (rawAccel - lastAccel)
        lastAccel = accel

        pendingDx += Double(dx * accel)
        pendingDy += Double(dy * accel)

        let sinceLastPostNs = lastPostTimestamp > 0 ? (now - lastPostTimestamp) : 20_000_000
        if sinceLastPostNs >= 6_000_000 || needMouseDown {
            let stepX = pendingDx * 0.60
            let stepY = pendingDy * 0.60
            pendingDx -= stepX
            pendingDy -= stepY

            let rawTarget = CGPoint(x: cachedX + stepX, y: cachedY + stepY)
            immediateTarget = snapToDisplayBoundsLocked(rawTarget)
            cachedX = immediateTarget.x
            cachedY = immediateTarget.y
            lastPostTimestamp = now
            shouldPostImmediate = true
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

        if shouldPostImmediate {
            postPointerEvent(at: immediateTarget, isDragging: true, coalesced: false)
        }
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
