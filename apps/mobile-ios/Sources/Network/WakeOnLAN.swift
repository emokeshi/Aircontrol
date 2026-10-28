import Foundation
import Darwin

public enum WoLError: LocalizedError {
    case invalidMacAddress
    case socketCreationFailed(Int32)
    case setBroadcastFailed(Int32)
    case sendFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidMacAddress:
            return "无效的网卡物理 MAC 地址（需形如 AA:BB:CC:DD:EE:FF）"
        case .socketCreationFailed(let code):
            return "创建 UDP Socket 失败 (errno: \(code))"
        case .setBroadcastFailed(let code):
            return "开启 UDP 广播失败 (errno: \(code))"
        case .sendFailed(let code):
            return "发送 WoL 魔术包失败 (errno: \(code))"
        }
    }
}

/// Industrial Wake-on-LAN (WoL) Magic Packet Generator & Broadcaster
public final class WakeOnLAN: @unchecked Sendable {
    public static let shared = WakeOnLAN()

    private init() {}

    /// Parses a string representation of a MAC address (e.g. "AA:BB:CC:DD:EE:FF", "aa-bb-cc-dd-ee-ff", or "AABBCCDDEEFF")
    public static func parseMacAddress(_ macString: String) -> [UInt8]? {
        let clean = macString
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard clean.count == 12 else { return nil }

        var bytes = [UInt8]()
        var index = clean.startIndex
        for _ in 0..<6 {
            let nextIndex = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }

        return bytes
    }

    /// Creates the standard 102-byte Magic Packet: 6 bytes of 0xFF followed by 16 repetitions of target MAC
    public static func createMagicPacket(macBytes: [UInt8]) -> Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }
        return packet
    }

    /// Synchronously sends a single WoL magic packet over UDP broadcast to 255.255.255.255 on specified port
    public static func sendMagicPacket(mac: String, port: UInt16 = 9) throws {
        guard let macBytes = parseMacAddress(mac) else {
            throw WoLError.invalidMacAddress
        }

        let magicPacket = createMagicPacket(macBytes: macBytes)

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw WoLError.socketCreationFailed(errno)
        }
        defer { close(fd) }

        var broadcastEnable: Int32 = 1
        let optRes = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
        guard optRes == 0 else {
            throw WoLError.setBroadcastFailed(errno)
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("255.255.255.255")

        let sent = magicPacket.withUnsafeBytes { rawPtr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(fd, rawPtr.baseAddress, magicPacket.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard sent == magicPacket.count else {
            throw WoLError.sendFailed(errno)
        }
    }

    /// Asynchronously wakes the target computer with a 3-burst transmission over port 9 & port 7
    public static func wake(mac: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard parseMacAddress(mac) != nil else {
            completion?(.failure(WoLError.invalidMacAddress))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var lastError: Error? = nil
            for _ in 0..<3 {
                do {
                    try sendMagicPacket(mac: mac, port: 9)
                    try sendMagicPacket(mac: mac, port: 7)
                } catch {
                    lastError = error
                }
                usleep(25_000) // 25ms spacing between bursts
            }

            DispatchQueue.main.async {
                if let err = lastError {
                    completion?(.failure(err))
                } else {
                    completion?(.success(()))
                }
            }
        }
    }
}
