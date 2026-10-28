import Foundation
import Network
import CoreGraphics
import os

public final class SocketServer: @unchecked Sendable {
    public static let shared = SocketServer()

    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var netService: NetService?
    private var activeTcpConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.aircontrol.socket.server", qos: .userInteractive)

    public private(set) var isRunning: Bool = false
    public var tcpPort: UInt16 = 8921
    public var udpPort: UInt16 = 8920

    public var hasActiveTcpClient: Bool {
        return activeTcpConnection != nil
    }

    private func onTcpClientDisconnected() {
        MultipeerServer.shared.resumeAdvertisingIfNeeded()
        DispatchQueue.main.async {
            if !MultipeerServer.shared.hasConnectedPeers {
                AppState.shared.connectedClient = nil
            }
        }
    }

    // Lock-protected 128-entry sequence number ring for multi-path (UDP en3 + UDP en0 + TCP_NODELAY) deduplication
    private var seqLock = os_unfair_lock()
    private var seenSeqRing = [UInt16](repeating: 0, count: 128)
    private var seenSeqValid = [Bool](repeating: false, count: 128)
    private var seenSeqCursor: Int = 0
    private var lastKeepAwakeReplyNs: UInt64 = 0

    private init() {}

    public func start(tcpPort: UInt16 = 8921, udpPort: UInt16 = 8920) {
        stop()
        self.tcpPort = tcpPort
        self.udpPort = udpPort

        startUdp(port: udpPort)
        startTcp(port: tcpPort)
        publishBonjour(port: tcpPort)
        isRunning = true

        DiagnosticLogger.shared.log("NET", "SocketServer listening on TCP:\(tcpPort) UDP:\(udpPort) (VPN utun bypassed)")

        SystemController.shared.startWorkspaceMonitoring(
            onAppListChanged: { [weak self] in
                self?.broadcastDockApps()
                MultipeerServer.shared.broadcastDockApps()
            },
            onActiveAppChanged: { [weak self] activeBundleId in
                self?.broadcastActiveApp(bundleId: activeBundleId)
                MultipeerServer.shared.broadcastActiveApp(bundleId: activeBundleId)
            }
        )
    }

    public func stop() {
        netService?.stop()
        netService = nil
        activeTcpConnection?.cancel()
        activeTcpConnection = nil
        tcpListener?.cancel()
        tcpListener = nil
        udpListener?.cancel()
        udpListener = nil
        isRunning = false
    }

    private func publishBonjour(port: UInt16) {
        let hostName = Host.current().localizedName ?? "Mac"
        netService = NetService(domain: "", type: "_aircontrol._tcp.", name: hostName, port: Int32(port))
        netService?.publish()
    }

    // MARK: - WMM High-Priority UDP Motion Listener (16-Byte Datagrams)

    private func startUdp(port: UInt16) {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        // Bypass virtual VPN TUN interfaces (utun) which have interface type .other
        params.prohibitedInterfaceTypes = [.other]

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleUdpConnection(connection)
        }
        listener.start(queue: queue)
        self.udpListener = listener
    }

    private func handleUdpConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        func receiveNext() {
            connection.receiveMessage { [weak self, weak connection] content, _, _, error in
                guard let self = self, let connection = connection, let data = content, error == nil else {
                    connection?.cancel()
                    return
                }
                if data.count >= 16 && data[0] == 0xA8 {
                    let eventType = data[1]
                    if eventType == 0xFE {
                        // Active UDP Echo Probe: immediately echo back 0xA8 0xFF with identical payload
                        var reply = data
                        reply[1] = 0xFF
                        connection.send(content: reply, completion: .idempotent)
                        if self.activeTcpConnection != nil {
                            MultipeerServer.shared.suspendForDirectSocket()
                        }
                    } else {
                        self.processMotionPacket(data, isUdp: true)
                        // Send a 4-byte 802.11 PM=0 Radio Keep-Awake pulse every 20ms during active motion
                        // so neither Mac nor iPhone Wi-Fi enters 102.4ms 802.11 PS-Poll Beacon sleep!
                        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        if (now - self.lastKeepAwakeReplyNs) >= 20_000_000 {
                            self.lastKeepAwakeReplyNs = now
                            let keepAwake = Data([0xA8, 0xFD, data[2], data[3]])
                            connection.send(content: keepAwake, completion: .idempotent)
                        }
                    }
                }
                receiveNext()
            }
        }
        receiveNext()
    }

    private func checkAndMarkSequence(_ seq: UInt16) -> Bool {
        os_unfair_lock_lock(&seqLock)
        for i in 0..<128 {
            if seenSeqValid[i] && seenSeqRing[i] == seq {
                os_unfair_lock_unlock(&seqLock)
                return false
            }
        }
        seenSeqRing[seenSeqCursor] = seq
        seenSeqValid[seenSeqCursor] = true
        seenSeqCursor = (seenSeqCursor + 1) & 127
        os_unfair_lock_unlock(&seqLock)
        return true
    }

    public func processMotionPacket(_ data: Data, isUdp: Bool = true) {
        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress else { return }

            let eventType = ptr.load(fromByteOffset: 1, as: UInt8.self)
            let rawSeq = ptr.load(fromByteOffset: 2, as: UInt16.self)
            let seq = UInt16(bigEndian: rawSeq)

            // Multi-path race deduplication: whichever path (en3 UDP, en0 UDP, or TCP_NODELAY) arrives first wins!
            if !checkAndMarkSequence(seq) {
                DiagnosticLogger.shared.recordDuplicateDrop()
                return
            }

            let rawFlags = ptr.load(fromByteOffset: 14, as: UInt16.self)
            let flags = UInt16(bigEndian: rawFlags)
            let isStrokeStart = (flags & 0x80) != 0

            DiagnosticLogger.shared.recordMotionRx(isUdp: isUdp, seq: seq, isStrokeStart: isStrokeStart)

            let rawDx = ptr.load(fromByteOffset: 4, as: UInt32.self)
            let rawDy = ptr.load(fromByteOffset: 8, as: UInt32.self)
            let dx = Float(bitPattern: UInt32(bigEndian: rawDx))
            let dy = Float(bitPattern: UInt32(bigEndian: rawDy))

            switch eventType {
            case 0x01:
                InputSimulator.shared.move(dx: dx, dy: dy)
            case 0x02:
                InputSimulator.shared.scroll(dx: dx, dy: dy)
            case 0x03:
                InputSimulator.shared.dragMove(dx: dx, dy: dy)
            case 0x04:
                if flags & 0x08 != 0 {
                    InputSimulator.shared.doubleClick()
                } else if flags & 0x02 != 0 {
                    InputSimulator.shared.rightClick()
                } else {
                    InputSimulator.shared.leftClick()
                }
            case 0x05:
                InputSimulator.shared.setDragging(false)
            case 0x06:
                InputSimulator.shared.setDragging(true)
            default:
                break
            }
        }
    }

    // MARK: - Low-Latency TCP_NODELAY Control & Redundant Motion Listener

    private func startTcp(port: UInt16) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        params.prohibitedInterfaceTypes = [.other]

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleTcpConnection(connection)
        }
        listener.start(queue: queue)
        self.tcpListener = listener
    }

    private func handleTcpConnection(_ connection: NWConnection) {
        activeTcpConnection?.cancel()
        activeTcpConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                DiagnosticLogger.shared.log("TCP", "Direct TCP client connected: \(String(describing: connection?.endpoint))")
                MultipeerServer.shared.suspendForDirectSocket()
            case .failed(let err):
                DiagnosticLogger.shared.log("TCP", "Direct TCP failed: \(err.localizedDescription)")
                if self.activeTcpConnection === connection {
                    self.activeTcpConnection = nil
                    self.onTcpClientDisconnected()
                }
            case .cancelled:
                if self.activeTcpConnection === connection {
                    self.activeTcpConnection = nil
                    self.onTcpClientDisconnected()
                }
            default:
                break
            }
        }

        connection.start(queue: queue)

        func readMessage() {
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] lengthData, _, _, error in
                guard let self = self, let connection = connection, let lenBytes = lengthData, lenBytes.count == 4, error == nil else {
                    if self?.activeTcpConnection === connection {
                        self?.activeTcpConnection = nil
                        self?.onTcpClientDisconnected()
                    }
                    connection?.cancel()
                    return
                }

                let payloadLength = Int(lenBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                guard payloadLength > 0 && payloadLength < 1_048_576 else {
                    connection.cancel()
                    return
                }

                connection.receive(minimumIncompleteLength: payloadLength, maximumLength: payloadLength) { [weak self, weak connection] payloadData, _, _, err in
                    guard let self = self, let connection = connection, let data = payloadData, err == nil else {
                        connection?.cancel()
                        return
                    }

                    // Fast-path: 16-byte binary motion packet over TCP_NODELAY (races in parallel with UDP)
                    if payloadLength == 16 && data[0] == 0xA8 {
                        self.processMotionPacket(data, isUdp: false)
                    } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String {
                        self.processTcpMessage(json, type: type, connection: connection)
                    }

                    readMessage()
                }
            }
        }

        readMessage()
    }

    private func sendTcpJson(_ object: [String: Any], connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(data.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)

        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    public func broadcastDockApps() {
        guard let conn = activeTcpConnection else { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            let apps = SystemController.shared.getRunningApplications(includeIcons: false)
            let appDicts: [[String: Any]] = apps.map { app in
                [
                    "bundle_id": app.bundleId,
                    "name": app.name,
                    "is_active": app.isActive
                ]
            }
            self.sendTcpJson(["type": "dock_list", "apps": appDicts], connection: conn)
        }
    }

    public func broadcastActiveApp(bundleId: String) {
        guard let conn = activeTcpConnection else { return }
        sendTcpJson(["type": "dock_active", "bundle_id": bundleId], connection: conn)
    }

    private func pushDockIcons(for bundleIds: [String], connection: NWConnection) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let icons = SystemController.shared.getCompressedIcons(for: bundleIds)
            guard !icons.isEmpty else { return }
            self.sendTcpJson(["type": "dock_icons", "icons": icons], connection: connection)
        }
    }

    private func processTcpMessage(_ json: [String: Any], type: String, connection: NWConnection) {
        switch type {
        case "client_hello", "host_query":
            if let clientName = json["client_name"] as? String {
                DispatchQueue.main.async {
                    AppState.shared.connectedClient = clientName
                }
                DiagnosticLogger.shared.log("TCP", "Handshake from '\(clientName)'")
            }
            AppState.shared.refreshLocalIP()
            sendTcpJson([
                "type": "host_ack",
                "status": "authenticated",
                "host_name": Host.current().localizedName ?? "Mac",
                "os": "macOS",
                "udp_port": Int(udpPort),
                "tcp_port": Int(tcpPort),
                "local_ip": AppState.shared.localIP,
                "local_ips": AppState.shared.localIPs,
                "mac_address": AppState.shared.macAddress,
                "volume": Double(SystemController.shared.getMasterVolume()),
                "natural_scroll": InputSimulator.shared.isNaturalScroll,
                "power_state": "awake"
            ], connection: connection)
            broadcastDockApps()

        case "ping":
            let clientTime = json["client_time"] ?? json["timestamp"] ?? 0.0
            sendTcpJson(["type": "pong", "client_time": clientTime], connection: connection)

        case "key_event":
            guard let keyCode = json["key_code"] as? UInt16,
                  let action = json["action"] as? String else { return }
            let isDown = (action == "down")
            var mods = KeyboardSimulator.Modifiers()
            if let modDict = json["modifiers"] as? [String: Bool] {
                mods = KeyboardSimulator.Modifiers(
                    cmd: modDict["cmd"] ?? false,
                    opt: modDict["opt"] ?? false,
                    ctrl: modDict["ctrl"] ?? false,
                    shift: modDict["shift"] ?? false
                )
            }
            DispatchQueue.main.async {
                KeyboardSimulator.shared.postKeyEvent(keyCode: keyCode, isDown: isDown, modifiers: mods)
            }

        case "text_commit":
            if let text = json["text"] as? String {
                DispatchQueue.main.async {
                    KeyboardSimulator.shared.typeUnicodeString(text)
                }
            }

        case "media_command":
            guard let action = json["action"] as? String else { return }
            DispatchQueue.main.async {
                switch action {
                case "volume_set":
                    if let val = json["value"] as? Double {
                        SystemController.shared.setMasterVolume(Float(val))
                    }
                case "volume_mute_toggle":
                    SystemController.shared.toggleMute()
                case "play_pause":
                    SystemController.shared.mediaPlayPause()
                case "next_track":
                    SystemController.shared.mediaNext()
                case "prev_track":
                    SystemController.shared.mediaPrevious()
                default:
                    break
                }
            }

        case "settings_update":
            if let natural = json["natural_scroll"] as? Bool {
                DispatchQueue.main.async {
                    AppState.shared.isNaturalScroll = natural
                }
            }

        case "dock_get":
            broadcastDockApps()

        case "dock_icons_get":
            if let ids = json["bundle_ids"] as? [String], !ids.isEmpty {
                pushDockIcons(for: ids, connection: connection)
            }

        case "app_activate":
            if let bundleId = json["bundle_id"] as? String {
                DispatchQueue.main.async {
                    SystemController.shared.activateApplication(bundleId: bundleId)
                }
            }

        case "app_terminate":
            if let bundleId = json["bundle_id"] as? String {
                DispatchQueue.main.async {
                    SystemController.shared.terminateApplication(bundleId: bundleId)
                }
            }

        case "power_command":
            guard let action = json["action"] as? String else { return }
            DispatchQueue.main.async {
                switch action {
                case "lock_screen":
                    SystemController.shared.lockScreen()
                case "display_sleep":
                    SystemController.shared.displaySleep()
                case "system_sleep":
                    SystemController.shared.systemSleep()
                case "shutdown":
                    SystemController.shared.shutdown()
                case "restart":
                    SystemController.shared.restart()
                default:
                    break
                }
            }

        case "host_logs_get":
            sendTcpJson([
                "type": "host_logs_reply",
                "summary": DiagnosticLogger.shared.statusSummary(),
                "lines": DiagnosticLogger.shared.recentLines(limit: 250)
            ], connection: connection)

        default:
            break
        }
    }
}
