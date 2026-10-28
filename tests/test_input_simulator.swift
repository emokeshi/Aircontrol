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

print("\n--- Test: CoreGraphics Mouse Event Generation & Boundary Snapping ---")

        // 1. Verify CGEventCreateMouseEvent works with absolute coordinate and nil source
        let targetPoint = CGPoint(x: 500, y: 300)
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: targetPoint,
            mouseButton: .left
        )
        assertTest(event != nil, "Successfully created CGEvent with nil source and absolute targetPoint")
        assertTest(event?.location.x == 500 && event?.location.y == 300, "Event location matches exactly (500, 300)")

        // 2. Verify delta fields are NOT set (remain 0 unless explicitly assigned)
        let deltaX = event?.getIntegerValueField(.mouseEventDeltaX) ?? 0
        let deltaY = event?.getIntegerValueField(.mouseEventDeltaY) ?? 0
        assertTest(deltaX == 0 && deltaY == 0, "mouseEventDeltaX & deltaY are zero (no double accumulation)")

        // 3. Multi-monitor display bounds test
        let mainDisplay = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainDisplay)
        assertTest(mainBounds.width > 0 && mainBounds.height > 0, "Retrieved valid primary display bounds: \(mainBounds)")

        var matchedDisplay: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let insidePoint = CGPoint(x: mainBounds.midX, y: mainBounds.midY)
        let status = CGGetDisplaysWithPoint(insidePoint, 1, &matchedDisplay, &count)
        assertTest(status == .success && count > 0, "CGGetDisplaysWithPoint correctly identifies inside point")

        // Test point outside bounds
        let outsidePoint = CGPoint(x: -99999, y: -99999)
        var outDisplay: CGDirectDisplayID = 0
        var outCount: UInt32 = 0
        let outStatus = CGGetDisplaysWithPoint(outsidePoint, 1, &outDisplay, &outCount)
        assertTest(outCount == 0 || outStatus != .success, "CGGetDisplaysWithPoint correctly detects out-of-bounds point")

print("🎉 Input Simulator & CoreGraphics Verification Passed! 🎉\n")
