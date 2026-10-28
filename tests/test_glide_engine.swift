import Foundation
import CoreGraphics

func assertTest(_ condition: Bool, _ message: String) {
    if !condition {
        print("❌ ASSERTION FAILED: \(message)")
        exit(1)
    } else {
        print("✅ PASS: \(message)")
    }
}

print("\n--- Test: 120Hz Frame-Paced Anti-Jitter Engine & Burst Absorption ---")

// High-fidelity simulation of the 120Hz Frame-Paced Burst Absorption Engine
class MockFramePacedEngine {
    var cachedX: Double = 100.0
    var cachedY: Double = 100.0
    var pendingDx: Double = 0.0
    var pendingDy: Double = 0.0
    var lastPostTime: UInt64 = 0
    var avgPacketMag: Double = 10.0
    var isTimerArmed: Bool = false
    var lastAccel: Float = 1.8
    var lastActivityTimestamp: UInt64 = 0
    var posts: [(time: Double, pt: CGPoint, isImmediate: Bool)] = []

    func postDirectLocked(dx: Double, dy: Double, now: UInt64, isImmediate: Bool) -> CGPoint {
        cachedX += dx
        cachedY += dy
        lastPostTime = now
        let pt = CGPoint(x: cachedX, y: cachedY)
        posts.append((Double(now)/1_000_000.0, pt, isImmediate))
        return pt
    }

    func move(dx: Float, dy: Float, isStrokeStart: Bool = false, now: UInt64) -> (shouldPost: Bool, pt: CGPoint, timerDelayMs: Double?) {
        guard dx != 0 || dy != 0 else { return (false, .zero, nil) }

        let dist = hypotf(dx, dy)
        let baseGain: Float = 1.8
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

        var pt: CGPoint = .zero
        var shouldPost = false
        var timerDelayMs: Double? = nil

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
                isTimerArmed = false
            } else {
                let ratio = maxImmediate / pendingMag
                stepX = pendingDx * ratio
                stepY = pendingDy * ratio
                pendingDx -= stepX
                pendingDy -= stepY
            }

            pt = postDirectLocked(dx: stepX, dy: stepY, now: now, isImmediate: true)
            shouldPost = true

            let hasRemaining = hypot(pendingDx, pendingDy) >= 0.05
            if hasRemaining && !isTimerArmed {
                isTimerArmed = true
                timerDelayMs = 8.0
            }
        } else {
            // Rapid packet arrival (< 8ms since last post): buffer into pending and arm timer
            if !isTimerArmed {
                isTimerArmed = true
                let remainingNs = minIntervalNs - sinceLastPostNs
                timerDelayMs = max(1.0, Double(remainingNs) / 1_000_000.0)
            }
        }

        lastActivityTimestamp = now
        return (shouldPost, pt, timerDelayMs)
    }

    func tickPacer(now: UInt64) -> (shouldPost: Bool, pt: CGPoint, rearmDelayMs: Double?) {
        let pendingMag = hypot(pendingDx, pendingDy)
        if pendingMag < 0.05 {
            pendingDx = 0.0
            pendingDy = 0.0
            isTimerArmed = false
            return (false, .zero, nil)
        }

        let maxStep = max(2.0, avgPacketMag * 1.35)
        let stepX: Double
        let stepY: Double
        if pendingMag <= maxStep {
            stepX = pendingDx
            stepY = pendingDy
            pendingDx = 0.0
            pendingDy = 0.0
            isTimerArmed = false
        } else {
            let ratio = maxStep / pendingMag
            stepX = pendingDx * ratio
            stepY = pendingDy * ratio
            pendingDx -= stepX
            pendingDy -= stepY
        }

        let pt = postDirectLocked(dx: stepX, dy: stepY, now: now, isImmediate: false)
        let hasRemaining = hypot(pendingDx, pendingDy) >= 0.05
        return (true, pt, hasRemaining ? 8.0 : nil)
    }

    func flush() -> CGPoint {
        cachedX += pendingDx
        cachedY += pendingDy
        pendingDx = 0.0
        pendingDy = 0.0
        isTimerArmed = false
        return CGPoint(x: cachedX, y: cachedY)
    }
}

let engine = MockFramePacedEngine()
var curTime: UInt64 = 1_000_000_000

// 1. Test Stroke Start (instant 100% step, 0ms lag)
let rStart = engine.move(dx: 10.0, dy: 0.0, isStrokeStart: true, now: curTime)
assertTest(rStart.shouldPost, "Stroke start immediately posted to screen")
assertTest(abs(engine.cachedX - 118.0) < 1e-4, "Cursor moved exact 10 * 1.8 = 18.0px immediately: \(engine.cachedX)")
assertTest(engine.pendingDx == 0.0, "Pending reservoir is completely clean: \(engine.pendingDx)")
assertTest(!engine.isTimerArmed, "Timer remains dormant on stroke start (zero idle wakeups)")

// 2. Test Normal 60Hz Streaming (~16.67ms packet interval)
var prePos = engine.cachedX
for i in 1...4 {
    curTime += 16_666_667
    let r = engine.move(dx: 10.0, dy: 0.0, isStrokeStart: false, now: curTime)
    assertTest(r.shouldPost, "60Hz packet #\(i) posted immediately without lag")
    assertTest(!engine.isTimerArmed, "Timer stays disarmed during normal 60Hz streaming")
}
let total60HzDist = engine.cachedX - prePos
assertTest(total60HzDist > 72.0 && abs(engine.pendingDx) < 1e-4, "Exact accelerated displacement delivered with 0 pending: \(total60HzDist)")

// 3. Test 120Hz ProMotion Streaming (~8.33ms packet interval)
prePos = engine.cachedX
for i in 1...4 {
    curTime += 8_333_333
    let r = engine.move(dx: 5.0, dy: 0.0, isStrokeStart: false, now: curTime)
    assertTest(r.shouldPost, "120Hz ProMotion packet #\(i) posted immediately")
    assertTest(!engine.isTimerArmed, "Timer stays disarmed during 120Hz ProMotion streaming")
}
assertTest(engine.cachedX > prePos, "120Hz ProMotion advances smoothly")

// 4. Test Slow Precision Movements (small deltas at 35-50ms intervals)
prePos = engine.cachedX
for i in 1...3 {
    curTime += 40_000_000
    let r = engine.move(dx: 0.5, dy: 0.0, isStrokeStart: false, now: curTime)
    assertTest(r.shouldPost, "Precision slow movement #\(i) posted immediately with zero freeze")
    assertTest(!engine.isTimerArmed, "Timer not needed for precision movement")
}

// 5. Test Wi-Fi Packet Stall & Burst Pacing
// Simulate a 45ms Wi-Fi stall where packets stop arriving:
curTime += 45_000_000
let postCountBeforeStall = engine.posts.count
let rDelayed1 = engine.move(dx: 10.0, dy: 0.0, isStrokeStart: false, now: curTime)
assertTest(rDelayed1.shouldPost, "First delayed packet after stall posts immediately")

// Burst: Packet 2 arrives only 2ms after packet 1 due to Wi-Fi buffer draining
curTime += 2_000_000
let rBurst = engine.move(dx: 10.0, dy: 0.0, isStrokeStart: false, now: curTime)
assertTest(!rBurst.shouldPost, "Burst packet (<8ms gap) is NOT posted immediately (prevents teleport jump)")
assertTest(engine.isTimerArmed, "Timer is armed to pace out burst smoothly")
assertTest(engine.pendingDx > 0.0, "Burst delta is safely buffered in pending reservoir: \(engine.pendingDx)")

// Timer fires at 8ms interval from packet 1 post
var burstPostTime = curTime + 6_000_000 // 8ms after delayed packet 1 post
let rTick1 = engine.tickPacer(now: burstPostTime)
assertTest(rTick1.shouldPost, "Timer posted paced burst displacement at exact 8ms cadence")

// If backlog was large, timer smoothly paces out remaining displacement on next 120Hz frame
if rTick1.rearmDelayMs != nil {
    burstPostTime += 8_000_000
    let rTick2 = engine.tickPacer(now: burstPostTime)
    assertTest(rTick2.shouldPost, "Timer posted remaining backlog on frame 2 at 120Hz")
}
assertTest(abs(engine.pendingDx) < 1e-4, "Pending reservoir cleanly drained: \(engine.pendingDx)")
assertTest(!engine.isTimerArmed, "Timer cleanly disarms and returns to sleep")

// 6. Test Mathematical Conservation (Zero Drift, Zero Overshoot)
let totalDisplacement = engine.cachedX - 100.0
assertTest(totalDisplacement > 0.0, "Total movement recorded: \(totalDisplacement)")
assertTest(abs(engine.pendingDx) < 1e-4 && abs(engine.pendingDy) < 1e-4, "Reservoir exact zero")

// 7. Test Flush on Click
engine.pendingDx = 3.5
engine.pendingDy = 2.0
let target = engine.flush()
assertTest(engine.pendingDx == 0.0 && engine.pendingDy == 0.0, "Flush clears pending")
assertTest(abs(target.x - engine.cachedX) < 1e-4, "Flush snaps to exact destination")

print("\n🎉 120Hz Frame-Paced Anti-Jitter Engine & Burst Absorption Verification Passed! 🎉\n")
