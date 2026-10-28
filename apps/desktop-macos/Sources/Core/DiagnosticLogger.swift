import Foundation
import Darwin
import os

public final class DiagnosticLogger: @unchecked Sendable {
    public static let shared = DiagnosticLogger()

    private var lock = os_unfair_lock()
    private var entries: [String] = []
    private let maxEntries = 600
    private let formatter: DateFormatter

    // Real-time motion telemetry counters
    private var udpPacketsReceived: UInt64 = 0
    private var mcPacketsReceived: UInt64 = 0
    private var coalescedBursts: UInt64 = 0
    private var seqGapCount: UInt64 = 0
    private var lastSeq: UInt16 = 0
    private var hasLastSeq: Bool = false

    private var lastRxTimeNs: UInt64 = 0
    private var intervalSumMs: Double = 0
    private var intervalCount: UInt64 = 0
    private var intervalMaxMs: Double = 0

    private var cgPostSumUs: Double = 0
    private var cgPostCount: UInt64 = 0
    private var cgPostMaxUs: Double = 0
    private var lastSummaryTimeNs: UInt64 = 0

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        log("SYS", "macOS Host DiagnosticLogger initialized. Interfaces: \(Self.describeInterfaces())")
    }

    public func log(_ category: String, _ message: String) {
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] [MAC:\(category)] \(message)"
        os_unfair_lock_lock(&lock)
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        os_unfair_lock_unlock(&lock)
    }

    public func recordMotionRx(isUdp: Bool, seq: UInt16) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var summaryLine: String? = nil

        os_unfair_lock_lock(&lock)
        if isUdp {
            udpPacketsReceived += 1
        } else {
            mcPacketsReceived += 1
        }

        if hasLastSeq {
            let expected = lastSeq &+ 1
            if seq != expected && seq > expected {
                seqGapCount += UInt64(seq - expected)
            }
        }
        lastSeq = seq
        hasLastSeq = true

        if lastRxTimeNs > 0 {
            let deltaMs = Double(now - lastRxTimeNs) / 1_000_000.0
            if deltaMs < 250.0 {
                intervalSumMs += deltaMs
                intervalCount += 1
                if deltaMs > intervalMaxMs {
                    intervalMaxMs = deltaMs
                }
            }
        }
        lastRxTimeNs = now

        if lastSummaryTimeNs == 0 {
            lastSummaryTimeNs = now
        } else if (now - lastSummaryTimeNs) >= 3_000_000_000 && intervalCount > 5 {
            let avgInterval = intervalSumMs / Double(intervalCount)
            let maxInterval = intervalMaxMs
            let avgCgUs = cgPostCount > 0 ? (cgPostSumUs / Double(cgPostCount)) : 0
            let maxCgUs = cgPostMaxUs
            summaryLine = String(
                format: "RX udp=%llu mc=%llu gaps=%llu coalesced=%llu | dt_avg=%.2fms dt_max=%.2fms | CGEvent_avg=%.0fus max=%.0fus",
                udpPacketsReceived, mcPacketsReceived, seqGapCount, coalescedBursts,
                avgInterval, maxInterval, avgCgUs, maxCgUs
            )
            intervalSumMs = 0
            intervalCount = 0
            intervalMaxMs = 0
            cgPostSumUs = 0
            cgPostCount = 0
            cgPostMaxUs = 0
            lastSummaryTimeNs = now
        }
        os_unfair_lock_unlock(&lock)

        if let s = summaryLine {
            log("PERF", s)
        }
    }

    public func recordCgEventPost(durationUs: Double, coalesced: Bool) {
        os_unfair_lock_lock(&lock)
        if coalesced {
            coalescedBursts += 1
        } else {
            cgPostSumUs += durationUs
            cgPostCount += 1
            if durationUs > cgPostMaxUs {
                cgPostMaxUs = durationUs
            }
        }
        os_unfair_lock_unlock(&lock)
    }

    public func recentLines(limit: Int = 200) -> [String] {
        os_unfair_lock_lock(&lock)
        let slice = Array(entries.suffix(limit))
        os_unfair_lock_unlock(&lock)
        return slice
    }

    public func statusSummary() -> [String: Any] {
        os_unfair_lock_lock(&lock)
        let udp = udpPacketsReceived
        let mc = mcPacketsReceived
        let gaps = seqGapCount
        let coal = coalescedBursts
        os_unfair_lock_unlock(&lock)

        return [
            "interfaces": Self.describeInterfaces(),
            "ax_trusted": AccessibilityManager.isTrusted,
            "udp_rx": udp,
            "mc_rx": mc,
            "seq_gaps": gaps,
            "coalesced": coal,
            "mc_advertising": MultipeerServer.shared.isAdvertising
        ]
    }

    public static func describeInterfaces() -> String {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return "none" }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name != "lo0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if !ip.isEmpty {
                        result.append("\(name)=\(ip)")
                    }
                }
            }
        }
        return result.joined(separator: ", ")
    }
}
