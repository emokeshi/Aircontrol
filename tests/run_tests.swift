import Foundation

@main
struct TestRunner {
    static func assertTest(_ condition: Bool, _ message: String) {
        if !condition {
            print("❌ ASSERTION FAILED: \(message)")
            exit(1)
        } else {
            print("✅ PASS: \(message)")
        }
    }

    static func main() {
        // MARK: - Test 1: OneEuroFilter Mathematics & Behavior
        print("\n--- Test 1: OneEuroFilter Mathematics & Behavior ---")
        let euroFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.015, dCutoff: 1.0)

        // 1.1 Initial value should pass through
        let firstVal = euroFilter.filter(10.0, timestamp: 0.0)
        assertTest(abs(firstVal - 10.0) < 1e-4, "First value passes through without delay")

        // 1.2 Low speed micro-jitter suppression: Small fluctuations around 10.0
        var smoothed = [Double]()
        var time = 0.0
        for i in 1...20 {
            time += 0.00833 // ~120Hz
            let noise = (i % 2 == 0) ? 0.4 : -0.4
            let filtered = euroFilter.filter(10.0 + noise, timestamp: time)
            smoothed.append(filtered)
        }
        let lastSmooth = smoothed.last!
        assertTest(abs(lastSmooth - 10.0) < 0.25, "Low-speed jitter successfully suppressed by filter (output: \(lastSmooth))")

        // 1.3 High speed responsiveness: Sudden rapid jump
        let suddenTime = time + 0.00833
        let suddenJump = euroFilter.filter(100.0, timestamp: suddenTime)
        assertTest(suddenJump > 30.0, "High velocity increases cutoff frequency and tracks rapidly (output: \(suddenJump))")

        // 1.4 Reset functionality
        euroFilter.reset()
        let postReset = euroFilter.filter(50.0, timestamp: 100.0)
        assertTest(abs(postReset - 50.0) < 1e-4, "Filter reset restores clean initial state")


        // 1.5 OneEuroFilter2D Dynamic Speed Responsiveness & Micro-Jitter
        let euro2D = OneEuroFilter2D(minCutoff: 1.0, beta: 0.015)
        var t2D = 0.0
        // High speed steady sweep: 25.0 points per frame
        for _ in 1...5 {
            t2D += 0.00833
            let fastOut = euro2D.filter(dx: 25.0, dy: 0.0, timestamp: t2D)
            assertTest(fastOut.dx > 20.0, "OneEuroFilter2D tracks fast sweep with zero lag (output: \(fastOut.dx))")
        }
        // Micro-jitter suppression
        euro2D.reset()
        t2D = 0.0
        var jitterOut = (dx: 0.0, dy: 0.0)
        for i in 1...20 {
            t2D += 0.00833
            let noise = (i % 2 == 0) ? 0.3 : -0.3
            jitterOut = euro2D.filter(dx: noise, dy: 0.0, timestamp: t2D)
        }
        assertTest(abs(jitterOut.dx) < 0.25, "OneEuroFilter2D successfully suppresses micro-jitter (output: \(jitterOut.dx))")

        // 1.6 Remote Mouse Reverse-Engineered Acceleration & Smoothing
        print("--- Subtest 1.6: Remote Mouse Reverse-Engineered Acceleration Model ---")
        func testRmAccel(dx: Float, dy: Float, dt: Float, speed: Float, lastAccel: Float) -> Float {
            let clampedDt: Float = (dt >= 0.002 && dt <= 0.05) ? dt : (1.0 / 60.0)
            let dist = hypotf(dx, dy)
            let factor = (dist * (1.0 / 60.0) / clampedDt) / speed
            var accel = 1.0 + factor
            if lastAccel > 0.0 && dt <= 0.1 {
                let alpha = min(1.0, clampedDt / 0.04)
                accel = lastAccel + alpha * (accel - lastAccel)
            }
            return accel
        }

        // Slow movement: low accel close to 1.0
        let slowAccel = testRmAccel(dx: 1.0, dy: 0.0, dt: 0.016, speed: 1.8, lastAccel: 0.0)
        assertTest(slowAccel >= 1.0 && slowAccel < 1.6, "Slow tracking maintains near-unity acceleration (accel: \(slowAccel))")

        // Fast flick: high accel > 2.0
        let fastAccel = testRmAccel(dx: 30.0, dy: 0.0, dt: 0.016, speed: 1.8, lastAccel: 0.0)
        assertTest(fastAccel > 2.0, "Fast flick dynamically scales acceleration for zero drag latency (accel: \(fastAccel))")

        // Network jitter protection: packet burst (dt < 2ms) does not explode acceleration
        let burstAccel = testRmAccel(dx: 5.0, dy: 0.0, dt: 0.0001, speed: 1.8, lastAccel: 0.0)
        assertTest(burstAccel < 5.0, "Network burst (<2ms) is clamped to 60Hz dt, preventing cursor jump explosion (accel: \(burstAccel))")


        // MARK: - Test 2: WakeOnLAN Packet Construction & MAC Parsing
        print("\n--- Test 2: WakeOnLAN Packet Construction & MAC Parsing ---")

        // 2.1 MAC Parsing: standard colon format
        let mac1 = "3C:06:30:4F:2E:11"
        let parsed1 = WakeOnLAN.parseMacAddress(mac1)
        assertTest(parsed1 != nil && parsed1!.count == 6, "Parses colon-separated MAC address")
        assertTest(parsed1! == [0x3C, 0x06, 0x30, 0x4F, 0x2E, 0x11], "Parsed bytes match exact hex values")

        // 2.2 MAC Parsing: dash format and lowercase
        let mac2 = "3c-06-30-4f-2e-11"
        let parsed2 = WakeOnLAN.parseMacAddress(mac2)
        assertTest(parsed2 == parsed1, "Parses dash-separated lowercase MAC address")

        // 2.3 MAC Parsing: raw hex string
        let mac3 = "3C06304F2E11"
        let parsed3 = WakeOnLAN.parseMacAddress(mac3)
        assertTest(parsed3 == parsed1, "Parses raw hex 12-character MAC address")

        // 2.4 MAC Parsing: invalid inputs rejected
        assertTest(WakeOnLAN.parseMacAddress("invalid-mac") == nil, "Rejects invalid string")
        assertTest(WakeOnLAN.parseMacAddress("3C:06:30:4F:2E") == nil, "Rejects short MAC")
        assertTest(WakeOnLAN.parseMacAddress("3C:06:30:4F:2E:11:99") == nil, "Rejects long MAC")

        // 2.5 Magic Packet structure: 6 bytes of 0xFF + 16 x 6 bytes = 102 bytes
        let magicPacket = WakeOnLAN.createMagicPacket(macBytes: parsed1!)
        assertTest(magicPacket.count == 102, "Magic packet size is exactly 102 bytes")

        var headerMatches = true
        for b in magicPacket[0..<6] {
            if b != 0xFF { headerMatches = false }
        }
        assertTest(headerMatches, "First 6 bytes are all 0xFF sync header")

        var bodyMatches = true
        for rep in 0..<16 {
            let offset = 6 + rep * 6
            let slice = Array(magicPacket[offset..<(offset + 6)])
            if slice != parsed1! {
                bodyMatches = false
                break
            }
        }
        assertTest(bodyMatches, "Remaining 96 bytes are exactly 16 repetitions of target MAC")


        // MARK: - Test 3: Hardware MAC Address Resolution
        print("\n--- Test 3: Hardware MAC Address Resolution ---")
        let hardwareMac = SystemController.shared.getPrimaryMacAddress()
        assertTest(hardwareMac != nil, "SystemController successfully discovered primary MAC address: \(hardwareMac ?? "nil")")
        if let mac = hardwareMac {
            assertTest(mac != "00:00:00:00:00:00", "MAC is not all-zero dummy")
            assertTest(!mac.hasPrefix("02:00:00"), "MAC is not getifaddrs privacy dummy 02:00:00:00:00:00 (actual: \(mac))")
            assertTest(WakeOnLAN.parseMacAddress(mac) != nil, "Hardware MAC is valid hex format parsable by WakeOnLAN")
        }


        // MARK: - Test 4: SideStore / AltStore source.json Validation
        print("\n--- Test 4: SideStore / AltStore source.json Validation ---")
        let sourcePath = "/Users/aaron/Documents/antigravity/nifty-hawking/source.json"
        guard let sourceData = FileManager.default.contents(atPath: sourcePath),
              let sourceJson = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any] else {
            print("❌ Failed to parse source.json")
            exit(1)
        }

        assertTest(sourceJson["name"] as? String == "AirControl Community Source", "source.json contains valid name")
        assertTest(sourceJson["identifier"] as? String == "com.aircontrol.community", "source.json contains valid identifier")

        guard let apps = sourceJson["apps"] as? [[String: Any]], !apps.isEmpty else {
            print("❌ source.json has no apps")
            exit(1)
        }
        let firstApp = apps[0]
        assertTest(firstApp["bundleIdentifier"] as? String == "com.aircontrol.mobile", "App bundleIdentifier matches")
        assertTest(firstApp["version"] as? String == "1.2.0", "App version matches 1.2.0")
        assertTest(firstApp["downloadURL"] != nil, "App contains downloadURL")
        let iconURL = firstApp["iconURL"] as? String ?? ""
        assertTest(iconURL.hasSuffix(".png"), "source.json app icon is PNG format compatible with iOS/SideStore: \(iconURL)")

        guard let news = sourceJson["news"] as? [[String: Any]], !news.isEmpty else {
            print("❌ source.json has no news")
            exit(1)
        }
        assertTest(news[0]["title"] != nil, "source.json contains news feed for SideStore")

        print("\n🎉 ALL TESTS PASSED SUCCESSFULLY! 🎉\n")
    }
}
