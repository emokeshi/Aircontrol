import Foundation
import Network
import CoreGraphics

public final class SocketServer: @unchecked Sendable {
    public static let shared = SocketServer()

    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var netService: NetService?
    private let queue = DispatchQueue(label: "com.aircontrol.socket.server", qos: .userInteractive)

    public private(set) var isRunning: Bool = false
    public var tcpPort: UInt16 = 8921
    public var udpPort: UInt16 = 8920

    private var lastSequenceNumber: UInt16 = 0

    private init() {}

    public func start(tcpPort: UInt16 = 8921, udpPort: UInt16 = 8920) {
        stop()
        self.tcpPort = tcpPort
        self.udpPort = udpPort

        startUdp(port: udpPort)
        startTcp(port: tcpPort)
        publishBonjour(port: tcpPort)
        isRunning = true
    }

    public func stop() {
        netService?.stop()
        netService = nil
        tcpListener?.cancel()
        tcpListener = nil
        udpListener?.cancel()
        udpListener = nil
        isRunning = false
    }

    // MARK: - Bonjour Advertisement

    private func publishBonjour(port: UInt16) {
        let hostName = Host.current().localizedName ?? "Mac"
        netService = NetService(domain: "", type: "_aircontrol._tcp.", name: "AirControl [\(hostName)]", port: Int32(port))
        netService?.publish()
    }

    // MARK: - UDP Motion Listener (16-Byte Datagrams)

    private func startUdp(port: UInt16) {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
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
            connection.receiveMessage { [weak self, weak connection] content, _, isComplete, error in
                guard let self = self, let data = content, error == nil else {
                    connection?.cancel()
                    return
                }
                if data.count == 16 && data[0] == 0xA8 {
                    self.processMotionPacket(data)
                }
                receiveNext()
            }
        }
        receiveNext()
    }

    private func processMotionPacket(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress else { return }

            let eventType = ptr.load(fromByteOffset: 1, as: UInt8.self)
            let rawDx = ptr.load(fromByteOffset: 4, as: UInt32.self)
            let rawDy = ptr.load(fromByteOffset: 8, as: UInt32.self)
            let dx = Float(bitPattern: UInt32(bigEndian: rawDx))
            let dy = Float(bitPattern: UInt32(bigEndian: rawDy))

            let rawFlags = ptr.load(fromByteOffset: 14, as: UInt16.self)
            let flags = UInt16(bigEndian: rawFlags)

            switch eventType {
            case 0x01: // Pointer Move
                InputSimulator.shared.move(dx: dx, dy: dy)
            case 0x02: // Scroll
                InputSimulator.shared.scroll(dx: dx, dy: dy)
            case 0x03: // Drag
                InputSimulator.shared.setDragging(true)
                InputSimulator.shared.move(dx: dx, dy: dy)
            case 0x04: // Click
                if flags & 0x08 != 0 {
                    InputSimulator.shared.doubleClick()
                } else if flags & 0x02 != 0 {
                    InputSimulator.shared.rightClick()
                } else {
                    InputSimulator.shared.leftClick()
                }
            case 0x05: // Drag release
                InputSimulator.shared.setDragging(false)
            default:
                break
            }
        }
    }

    // MARK: - TCP Control Listener

    private func startTcp(port: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleTcpConnection(connection)
        }
        listener.start(queue: queue)
        self.tcpListener = listener
    }

    private func handleTcpConnection(_ connection: NWConnection) {
        connection.start(queue: queue)

        func readMessage() {
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] lengthData, _, isComplete, error in
                guard let self = self, let connection = connection, let lenBytes = lengthData, lenBytes.count == 4, error == nil else {
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

                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    private func processTcpMessage(_ json: [String: Any], type: String, connection: NWConnection) {
        switch type {
        case "client_hello":
            let clientName = json["client_name"] as? String ?? "iOS Client"
            DispatchQueue.main.async {
                AppState.shared.connectedClient = clientName
            }
            sendTcpJson([
                "type": "host_ack",
                "status": "authenticated",
                "host_name": Host.current().localizedName ?? "Mac",
                "os": "macOS",
                "udp_port": Int(udpPort),
                "local_ip": AppState.shared.localIP,
                "mac_address": AppState.shared.macAddress,
                "power_state": "awake",
                "update_port": Int(AppState.shared.updatePort)
            ], connection: connection)

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

        case "dock_get":
            DispatchQueue.global(qos: .userInitiated).async {
                let apps = SystemController.shared.getRunningApplications()
                let appDicts: [[String: Any]] = apps.map { app in
                    var d: [String: Any] = [
                        "bundle_id": app.bundleId,
                        "name": app.name,
                        "is_active": app.isActive
                    ]
                    if let icon = app.iconBase64 {
                        d["icon_base64"] = icon
                    }
                    return d
                }
                self.sendTcpJson(["type": "dock_list", "apps": appDicts], connection: connection)
            }

        case "app_activate":
            if let bundleId = json["bundle_id"] as? String {
                DispatchQueue.main.async {
                    SystemController.shared.activateApplication(bundleId: bundleId)
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

        default:
            break
        }
    }
}
