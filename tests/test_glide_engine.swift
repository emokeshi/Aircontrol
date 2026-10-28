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

print("\n--- Test: Anti-Jitter Frame-Paced Engine & Dead Reckoning Mathematics ---")

// Simulation of the Anti-Jitter Glide Engine
class MockGlideEngine {
    var cachedX: Double = 100.0
    var cachedY: Double = 100.0
    var pendingDx: Double = 0.0
    var pendingDy: Double = 0.0
    var borrowedDx: Double = 0.0
    var borrowedDy: Double = 0.0
    var velX: Double = 0.0
    var velY: Double = 0.0
    var lastPacketTimestamp: UInt64 = 0
    var lastTickTimestamp: UInt64 = 0
    var lastAccel: Float = 1.8
    var posts: [CGPoint] = []

    func move(dx: Float, dy: Float, isStrokeStart: Bool, now: UInt64) {
        let dist = hypotf(dx, dy)
        let baseGain: Float = 1.8
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
            let stepX = deltaX * 0.75
            let stepY = deltaY * 0.75
            pendingDx = deltaX - stepX
            pendingDy = deltaY - stepY
            borrowedDx = 0.0
            borrowedDy = 0.0
            cachedX += stepX
            cachedY += stepY
            posts.append(CGPoint(x: cachedX, y: cachedY))
        } else {
            var finalDeltaX = deltaX
            var finalDeltaY = deltaY
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
    }

    func tick(now: UInt64) {
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
            if pendingMag < 0.6 {
                stepX = pendingDx
                stepY = pendingDy
                pendingDx = 0.0
                pendingDy = 0.0
            } else {
                let drainRatio = min(0.60, max(0.35, 1.0 / (16.0 / dtMs)))
                stepX = pendingDx * drainRatio
                stepY = pendingDy * drainRatio
                pendingDx -= stepX
                pendingDy -= stepY
            }
        } else if sinceLastPacketMs < 35.0 && (abs(velX) > 0.02 || abs(velY) > 0.02) {
            let decay = max(0.0, 1.0 - (sinceLastPacketMs - 16.0) / 19.0)
            stepX = velX * dtMs * decay * 0.50
            stepY = velY * dtMs * decay * 0.50
            borrowedDx += stepX
            borrowedDy += stepY
        } else {
            velX = 0.0
            velY = 0.0
            pendingDx = 0.0
            pendingDy = 0.0
            borrowedDx = 0.0
            borrowedDy = 0.0
        }

        let stepMag = hypot(stepX, stepY)
        if stepMag > 0.02 {
            cachedX += stepX
            cachedY += stepY
            posts.append(CGPoint(x: cachedX, y: cachedY))
        }
    }

    func flush() -> CGPoint {
        cachedX += pendingDx
        cachedY += pendingDy
        pendingDx = 0.0
        pendingDy = 0.0
        velX = 0.0
        velY = 0.0
        borrowedDx = 0.0
        borrowedDy = 0.0
        return CGPoint(x: cachedX, y: cachedY)
    }
}

// 1. Test Stroke Start (instant 75% step)
let engine = MockGlideEngine()
engine.move(dx: 10.0, dy: 0.0, isStrokeStart: true, now: 1_000_000_000)
assertTest(engine.posts.count == 1, "Immediate post on stroke start")
assertTest(abs(engine.cachedX - 113.5) < 0.1, "Cursor stepped 75% of (10 * 1.8) immediately: \(engine.cachedX)")
assertTest(abs(engine.pendingDx - 4.5) < 0.1, "Remaining 25% placed in pending reservoir: \(engine.pendingDx)")

// 2. Test 240Hz glide drain
engine.tick(now: 1_004_166_667)
assertTest(engine.posts.count == 2, "Second post on first timer tick")
let firstTickX = engine.cachedX
assertTest(firstTickX > 113.5, "Cursor progressed smoothly during tick: \(firstTickX)")

// Drain the rest of the reservoir over ticks up to 24ms
var curTime: UInt64 = 1_004_166_667
for _ in 1...6 {
    curTime += 4_166_667
    engine.tick(now: curTime)
}
assertTest(engine.pendingDx == 0.0, "Pending reservoir drained to 0 before stall: \(engine.pendingDx)")

// 3. Test Wi-Fi packet stall with dead-reckoning extrapolation
// Simulate stall: curTime is now > 20ms since last packet (which was at 1_000_000_000)
let preStallPosts = engine.posts.count
let preStallX = engine.cachedX
curTime += 4_166_667 // ~25ms since last packet
engine.tick(now: curTime)
assertTest(engine.posts.count > preStallPosts, "Dead-reckoning posted extrapolated movement during Wi-Fi stall!")
assertTest(engine.cachedX > preStallX, "Cursor advanced forward during stall: \(engine.cachedX) > \(preStallX)")
assertTest(engine.borrowedDx > 0.0, "Borrowed displacement recorded: \(engine.borrowedDx)")
assertTest(engine.pendingDx == 0.0, "Pending reservoir remained 0 (no reverse jitter): \(engine.pendingDx)")

// 4. Test delayed burst arrival after stall
// Delayed packet arrives:
let borrowedBeforeBurst = engine.borrowedDx
engine.move(dx: 10.0, dy: 0.0, isStrokeStart: false, now: curTime + 1_000_000)
// The incoming delta should have absorbed borrowedDx:
assertTest(engine.borrowedDx == 0.0, "Borrowed displacement cleanly absorbed")
// Pending should be incoming delta minus borrowed displacement
assertTest(engine.pendingDx > 0.0, "Pending reservoir has absorbed delta: \(engine.pendingDx)")

// 5. Test clean halt on finger stop
var stopTime = curTime + 50_000_000
for _ in 1...10 {
    stopTime += 4_166_667
    engine.tick(now: stopTime)
}
assertTest(abs(engine.pendingDx) < 1e-4 && abs(engine.pendingDy) < 1e-4, "Pending reservoir completely drained to 0.0 on stop")
assertTest(engine.velX == 0.0 && engine.velY == 0.0, "Velocity cleanly reset to 0.0 on stop (no ice-skating drift)")

// 6. Test flush on click
engine.pendingDx = 1.5
engine.pendingDy = 2.0
let target = engine.flush()
assertTest(engine.pendingDx == 0.0 && engine.pendingDy == 0.0, "Flush clears pending")
assertTest(abs(target.x - engine.cachedX) < 1e-4, "Flush snapped target matches cached position")

print("🎉 Anti-Jitter Frame-Paced Engine & Dead Reckoning Verification Passed! 🎉\n")
