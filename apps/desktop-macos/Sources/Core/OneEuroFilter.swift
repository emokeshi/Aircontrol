import Foundation

/// Internal 1st-order Low-Pass Filter
private final class LowPassFilter: @unchecked Sendable {
    private var hatXPrev: Double?

    func filter(_ x: Double, alpha: Double) -> Double {
        if let prev = hatXPrev {
            let hatX = alpha * x + (1.0 - alpha) * prev
            self.hatXPrev = hatX
            return hatX
        } else {
            self.hatXPrev = x
            return x
        }
    }

    var lastValue: Double? {
        hatXPrev
    }

    func reset() {
        hatXPrev = nil
    }
}

/// Industrial-Grade 1€ Adaptive Low-Pass Filter
/// Reference: Casiez, G., Roussel, N., and Vogel, D. (CHI 2012)
/// Dynamically balances low-speed jitter elimination and high-speed zero-latency tracking.
public final class OneEuroFilter: @unchecked Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private let xFilter = LowPassFilter()
    private let dxFilter = LowPassFilter()
    private var lastTime: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private func calculateAlpha(rate: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * max(cutoff, 1e-4))
        let te = 1.0 / max(rate, 1e-4)
        return 1.0 / (1.0 + tau / te)
    }

    public func filter(_ x: Double, timestamp: Double) -> Double {
        guard let prevTime = lastTime else {
            lastTime = timestamp
            return xFilter.filter(x, alpha: 1.0)
        }

        let dt = max(timestamp - prevTime, 1e-4)
        lastTime = timestamp
        let rate = 1.0 / dt

        // Estimate derivative of the signal
        let prevX = xFilter.lastValue ?? x
        let dx = (x - prevX) * rate
        let alphaD = calculateAlpha(rate: rate, cutoff: dCutoff)
        let edx = dxFilter.filter(dx, alpha: alphaD)

        // Dynamically compute cutoff based on speed
        let cutoff = minCutoff + beta * abs(edx)
        let alpha = calculateAlpha(rate: rate, cutoff: cutoff)

        return xFilter.filter(x, alpha: alpha)
    }

    public func reset() {
        xFilter.reset()
        dxFilter.reset()
        lastTime = nil
    }
}

/// 2D Adaptive One-Euro Filter for Trackpad & Cursor Displacement
public final class OneEuroFilter2D: @unchecked Sendable {
    public var minCutoff: Double
    public var beta: Double

    private var hatX: Double?
    private var hatY: Double?
    private var lastTime: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0.015, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private func calculateAlpha(rate: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * max(cutoff, 1e-4))
        let te = 1.0 / max(rate, 1e-4)
        return 1.0 / (1.0 + tau / te)
    }

    public func filter(dx: Double, dy: Double, timestamp: Double) -> (dx: Double, dy: Double) {
        guard let prevTime = lastTime, let prevX = hatX, let prevY = hatY else {
            lastTime = timestamp
            hatX = dx
            hatY = dy
            return (dx, dy)
        }

        let dt = max(timestamp - prevTime, 1e-4)
        lastTime = timestamp
        let rate = 1.0 / dt

        // Dynamic 2D speed in points per second
        let speed = sqrt(dx * dx + dy * dy) * rate
        let cutoff = minCutoff + beta * speed
        let alpha = calculateAlpha(rate: rate, cutoff: cutoff)

        let outX = alpha * dx + (1.0 - alpha) * prevX
        let outY = alpha * dy + (1.0 - alpha) * prevY

        hatX = outX
        hatY = outY

        return (outX, outY)
    }

    public func reset() {
        hatX = nil
        hatY = nil
        lastTime = nil
    }
}
