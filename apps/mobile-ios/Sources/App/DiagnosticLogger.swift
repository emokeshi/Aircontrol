import Foundation
import UIKit
import Darwin
import os

public final class DiagnosticLogger: ObservableObject, @unchecked Sendable {
    public static let shared = DiagnosticLogger()

    private var lock = os_unfair_lock()
    @Published public private(set) var entries: [String] = []
    @Published public private(set) var hostLines: [String] = []
    @Published public private(set) var hostSummary: [String: Any] = [:]

    private let maxEntries = 800
    private let formatter: DateFormatter

    // Client telemetry counters
    public private(set) var udpTxCount: UInt64 = 0
    public private(set) var mcTxCount: UInt64 = 0
    public private(set) var udpEchoCount: UInt64 = 0
    public private(set) var lastDockSyncMs: Int = 0

    private var lastTxTimeNs: UInt64 = 0
    private var intervalSumMs: Double = 0
    private var intervalCount: UInt64 = 0
    private var intervalMaxMs: Double = 0
    private var lastSummaryTimeNs: UInt64 = 0

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        log("SYS", "iOS DiagnosticLogger initialized. Device=\(UIDevice.current.model) iOS=\(UIDevice.current.systemVersion)")
        log("NET", "Active iOS interfaces: \(Self.describeInterfaces())")
    }

    public func log(_ category: String, _ message: String) {
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] [IOS:\(category)] \(message)"
        os_unfair_lock_lock(&lock)
        var current = entries
        current.append(line)
        if current.count > maxEntries {
            current.removeFirst(current.count - maxEntries)
        }
        os_unfair_lock_unlock(&lock)

        DispatchQueue.main.async {
            self.entries = current
        }
    }

    public func recordMotionTx(viaUdp: Bool, activeChannelDesc: String) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var summaryLine: String? = nil

        os_unfair_lock_lock(&lock)
        if viaUdp {
            udpTxCount += 1
        } else {
            mcTxCount += 1
        }

        if lastTxTimeNs > 0 {
            let dtMs = Double(now - lastTxTimeNs) / 1_000_000.0
            if dtMs < 250.0 {
                intervalSumMs += dtMs
                intervalCount += 1
                if dtMs > intervalMaxMs {
                    intervalMaxMs = dtMs
                }
            }
        }
        lastTxTimeNs = now

        if lastSummaryTimeNs == 0 {
            lastSummaryTimeNs = now
        } else if (now - lastSummaryTimeNs) >= 3_000_000_000 && intervalCount > 5 {
            let avgDt = intervalSumMs / Double(intervalCount)
            let maxDt = intervalMaxMs
            summaryLine = String(
                format: "TX ch=%@ udp_tx=%llu mc_tx=%llu echoes=%llu | dt_avg=%.2fms dt_max=%.2fms",
                activeChannelDesc, udpTxCount, mcTxCount, udpEchoCount, avgDt, maxDt
            )
            intervalSumMs = 0
            intervalCount = 0
            intervalMaxMs = 0
            lastSummaryTimeNs = now
        }
        os_unfair_lock_unlock(&lock)

        if let s = summaryLine {
            log("PERF", s)
        }
    }

    public func recordUdpEcho(rttMs: Int) {
        os_unfair_lock_lock(&lock)
        udpEchoCount += 1
        let count = udpEchoCount
        os_unfair_lock_unlock(&lock)

        if count == 1 || count % 15 == 0 {
            log("UDP", "UDP Direct echo #\(count) verified (RTT=\(rttMs)ms)")
        }
    }

    public func recordDockSync(appCount: Int, elapsedMs: Int, payloadBytes: Int) {
        os_unfair_lock_lock(&lock)
        lastDockSyncMs = elapsedMs
        os_unfair_lock_unlock(&lock)
        log("DOCK", "Synced \(appCount) apps in \(elapsedMs)ms (\(payloadBytes) bytes)")
    }

    public func updateHostLogs(summary: [String: Any], lines: [String]) {
        DispatchQueue.main.async {
            self.hostSummary = summary
            self.hostLines = lines
        }
    }

    public func clear() {
        os_unfair_lock_lock(&lock)
        udpTxCount = 0
        mcTxCount = 0
        intervalSumMs = 0
        intervalCount = 0
        intervalMaxMs = 0
        os_unfair_lock_unlock(&lock)

        DispatchQueue.main.async {
            self.entries.removeAll()
            self.hostLines.removeAll()
            self.log("SYS", "Logs cleared by user. Interfaces: \(Self.describeInterfaces())")
        }
    }

    public func buildExportText() -> String {
        let client = MultipeerClient.shared
        var out: [String] = []
        out.append("====================================================")
        out.append("AirControl Diagnostic Report")
        out.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("====================================================")
        out.append("")
        out.append("--- [1] iOS Client Status ---")
        out.append("Connected: \(client.isConnected) | Host: \(client.connectedHostName)")
        out.append("Motion Channel: \(client.activeMotionChannelName)")
        out.append("Control Channel: \(client.activeControlChannelName)")
        out.append("Target IP: \(client.hostIP) | Candidate IPs: \(client.candidateHostIPs.joined(separator: ", "))")
        out.append("UDP Verified: \(client.isUdpVerified) (UDP RTT: \(client.udpRttMs)ms) | Control RTT: \(client.latencyMs)ms")
        out.append("Packets Sent: UDP=\(udpTxCount), MCSession=\(mcTxCount), UDP Echoes=\(udpEchoCount)")
        out.append("Dock Apps: \(client.dockApps.count) (Last Sync: \(lastDockSyncMs)ms, Cached Icons: \(client.cachedIconCount))")
        out.append("iOS Network Interfaces: \(Self.describeInterfaces())")
        out.append("")
        out.append("--- [2] macOS Host Status ---")
        if hostSummary.isEmpty {
            out.append("(No host summary fetched yet)")
        } else {
            for (k, v) in hostSummary.sorted(by: { $0.key < $1.key }) {
                out.append("\(k): \(v)")
            }
        }
        out.append("")
        out.append("--- [3] iOS Client Timeline (\(entries.count) lines) ---")
        out.append(contentsOf: entries)
        out.append("")
        out.append("--- [4] macOS Host Timeline (\(hostLines.count) lines) ---")
        if hostLines.isEmpty {
            out.append("(No macOS logs received yet)")
        } else {
            out.append(contentsOf: hostLines)
        }
        out.append("====================================================")
        return out.joined(separator: "\n")
    }

    public func writeExportFile() -> URL? {
        let text = buildExportText()
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("aircontrol-diagnostic.log")
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
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
        return result.isEmpty ? "no-ipv4" : result.joined(separator: ", ")
    }
}
