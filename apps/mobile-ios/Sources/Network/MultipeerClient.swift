import Foundation
import MultipeerConnectivity
import UIKit
import Combine
import Network

public struct RemoteApp: Identifiable, Hashable {
    public var id: String { bundleId }
    public let bundleId: String
    public let name: String
    public let isActive: Bool
    public let iconBase64: String?

    public init(bundleId: String, name: String, isActive: Bool, iconBase64: String?) {
        self.bundleId = bundleId
        self.name = name
        self.isActive = isActive
        self.iconBase64 = iconBase64
    }
}

public final class MultipeerClient: NSObject, ObservableObject, @unchecked Sendable,
    MCSessionDelegate, MCNearbyServiceBrowserDelegate, NetServiceBrowserDelegate, NetServiceDelegate {

    public static let shared = MultipeerClient()

    private let serviceType = "aircontrol-p2p"
    private var myPeerID: MCPeerID!
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser!

    private var netBrowser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []
    private var tcpConnection: NWConnection?
    private var udpConnection: NWConnection?
    private let socketQueue = DispatchQueue(label: "com.aircontrol.client.socket", qos: .userInteractive)

    @Published public var isConnected: Bool = false
    @Published public var connectedHostName: String = UserDefaults.standard.string(forKey: "aircontrol_saved_host_name") ?? ""
    @Published public var hostIP: String = UserDefaults.standard.string(forKey: "aircontrol_saved_host_ip") ?? ""
    @Published public var targetMacAddress: String = UserDefaults.standard.string(forKey: "aircontrol_saved_mac") ?? ""
    @Published public var hostVolume: Float = 0.5
    @Published public var isNaturalScroll: Bool = true
    @Published public var latencyMs: Int = 0
    @Published public var dockApps: [RemoteApp] = []
    @Published public var discoveredHosts: [MCPeerID] = []
    @Published public var isSearching: Bool = true

    private var connectedPeer: MCPeerID?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var sequenceNumber: UInt16 = 0

    private override init() {
        super.init()
        setupPeer()
        setupLifecycleObservers()
    }

    private func setupPeer() {
        myPeerID = MCPeerID(displayName: UIDevice.current.name)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser.delegate = self
    }

    public func start() {
        if browser == nil || session == nil {
            setupPeer()
        }

        isSearching = !isConnected

        // 1. 0ms Instant Fast-Path: Immediately dial last known Mac IP without waiting for Bonjour scan
        let savedIP = hostIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !savedIP.isEmpty && !isConnected {
            connectDirectSockets(host: savedIP, tcpPort: 8921, udpPort: 8920)
        }

        // 2. If Mac is sleeping, silently send a background Wake-on-LAN packet so it wakes automatically
        let savedMac = targetMacAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !savedMac.isEmpty && !isConnected {
            WakeOnLAN.wake(mac: savedMac, completion: nil)
        }

        // 3. Discovery fallback (automatically stops as soon as connected to prevent Wi-Fi scan stutter)
        if !isConnected {
            browser.startBrowsingForPeers()
            netBrowser?.stop()
            netBrowser = NetServiceBrowser()
            netBrowser?.delegate = self
            netBrowser?.searchForServices(ofType: "_aircontrol._tcp.", inDomain: "")
        }

        startReconnectMonitor()
    }

    /// Stops background radio scanning once connected so Wi-Fi chip never hops off the main channel
    private func pauseBackgroundScanning() {
        browser?.stopBrowsingForPeers()
        netBrowser?.stop()
        resolvingServices.removeAll()
        isSearching = false
    }

    public func rescan() {
        discoveredHosts.removeAll()
        isSearching = true
        browser?.startBrowsingForPeers()
        netBrowser?.stop()
        netBrowser = NetServiceBrowser()
        netBrowser?.delegate = self
        netBrowser?.searchForServices(ofType: "_aircontrol._tcp.", inDomain: "")
    }

    public func stop() {
        pauseBackgroundScanning()
        session?.disconnect()
        tcpConnection?.cancel()
        tcpConnection = nil
        udpConnection?.cancel()
        udpConnection = nil
        stopPingLoop()
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        DispatchQueue.main.async {
            self.isConnected = false
            self.latencyMs = 0
            self.connectedPeer = nil
            self.isSearching = false
        }
    }

    public func connect(to peerID: MCPeerID) {
        if let current = connectedPeer, current != peerID {
            session.disconnect()
        }
        connectedPeer = peerID
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 6)
    }

    // MARK: - App Lifecycle & Silent Self-Healing

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if !self.isConnected {
                self.start()
            } else {
                self.sendHostQuery()
                self.requestDock()
                self.startPingLoop()
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopPingLoop()
        }
    }

    private func startReconnectMonitor() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.isConnected else { return }
            let ip = self.hostIP.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty && self.tcpConnection == nil {
                self.connectDirectSockets(host: ip, tcpPort: 8921, udpPort: 8920)
            }
        }
    }

    // MARK: - MCNearbyServiceBrowserDelegate

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if !self.discoveredHosts.contains(peerID) {
                self.discoveredHosts.append(peerID)
            }
            if !self.isConnected && self.connectedPeer == nil {
                self.connect(to: peerID)
            }
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.discoveredHosts.removeAll(where: { $0 == peerID })
        }
    }

    // MARK: - MCSessionDelegate

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.isConnected = true
                self.connectedPeer = peerID
                self.connectedHostName = peerID.displayName
                UserDefaults.standard.set(peerID.displayName, forKey: "aircontrol_saved_host_name")
                self.pauseBackgroundScanning()
                self.sendHostQuery()
                self.startPingLoop()
                self.requestDock()
            case .notConnected:
                if self.connectedPeer == peerID {
                    self.connectedPeer = nil
                    if self.tcpConnection == nil {
                        self.isConnected = false
                        self.latencyMs = 0
                        self.stopPingLoop()
                        self.start()
                    }
                }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            handleReceivedJson(json, type: type)
        }
    }

    // MARK: - Direct WMM UDP + TCP_NODELAY Socket Engine

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.append(service)
        service.resolve(withTimeout: 3.0)
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else { return }
        for addressData in addresses {
            var storage = sockaddr_storage()
            (addressData as NSData).getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)
            if storage.ss_family == sa_family_t(AF_INET) {
                let addr4 = withUnsafePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                }
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var sinAddr = addr4.sin_addr
                inet_ntop(AF_INET, &sinAddr, &hostBuffer, socklen_t(hostBuffer.count))
                let ipStr = String(cString: hostBuffer)

                if ipStr != "127.0.0.1" && !ipStr.isEmpty {
                    connectDirectSockets(host: ipStr, tcpPort: UInt16(sender.port), udpPort: 8920)
                    break
                }
            }
        }
    }

    private func setupUdpChannel(host: String, port: UInt16 = 8920) {
        udpConnection?.cancel()
        let udpParams = NWParameters.udp
        // 802.11e WMM Voice/Video QoS tag to bypass Wi-Fi router packet aggregation jitter
        udpParams.serviceClass = .interactiveVideo

        let udpEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let udp = NWConnection(to: udpEndpoint, using: udpParams)
        udp.start(queue: socketQueue)
        self.udpConnection = udp
    }

    private func connectDirectSockets(host: String, tcpPort: UInt16 = 8921, udpPort: UInt16 = 8920) {
        self.hostIP = host
        UserDefaults.standard.set(host, forKey: "aircontrol_saved_host_ip")

        setupUdpChannel(host: host, port: udpPort)

        guard tcpConnection == nil else { return }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 3
        let tcpParams = NWParameters(tls: nil, tcp: tcpOptions)
        tcpParams.serviceClass = .interactiveVideo

        let tcpEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: tcpPort)!)
        let tcp = NWConnection(to: tcpEndpoint, using: tcpParams)
        tcp.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.pauseBackgroundScanning()
                    self.startPingLoop()
                    self.sendJson(["type": "client_hello", "client_name": UIDevice.current.name])
                    self.requestDock()
                }
                self.receiveTcpStream(from: tcp)
            case .failed, .cancelled:
                DispatchQueue.main.async {
                    self.tcpConnection = nil
                    if self.connectedPeer == nil {
                        self.isConnected = false
                    }
                }
            default:
                break
            }
        }
        tcp.start(queue: socketQueue)
        self.tcpConnection = tcp
    }

    private func receiveTcpStream(from connection: NWConnection) {
        func readNext() {
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] lenData, _, _, error in
                guard let self = self, let connection = connection, let lenBytes = lenData, lenBytes.count == 4, error == nil else {
                    DispatchQueue.main.async {
                        self?.tcpConnection = nil
                        if self?.connectedPeer == nil {
                            self?.isConnected = false
                        }
                    }
                    return
                }
                let payloadLen = Int(lenBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                guard payloadLen > 0 && payloadLen < 1_048_576 else { return }

                connection.receive(minimumIncompleteLength: payloadLen, maximumLength: payloadLen) { [weak self] payloadData, _, _, err in
                    guard let self = self, let data = payloadData, err == nil else { return }
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let type = json["type"] as? String {
                        self.handleReceivedJson(json, type: type)
                    }
                    readNext()
                }
            }
        }
        readNext()
    }

    // MARK: - Unified Packet Dispatch & Receive

    private func handleReceivedJson(_ json: [String: Any], type: String) {
        DispatchQueue.main.async {
            switch type {
            case "host_ack":
                if let hostName = json["host_name"] as? String {
                    self.connectedHostName = hostName
                    UserDefaults.standard.set(hostName, forKey: "aircontrol_saved_host_name")
                }
                if let ip = json["local_ip"] as? String, !ip.isEmpty, ip != "127.0.0.1" {
                    let udpPort = UInt16(json["udp_port"] as? Int ?? 8920)
                    if self.hostIP != ip || self.udpConnection == nil {
                        self.hostIP = ip
                        UserDefaults.standard.set(ip, forKey: "aircontrol_saved_host_ip")
                        // Upgrade motion channel immediately to direct WMM UDP to bypass awdl0
                        self.setupUdpChannel(host: ip, port: udpPort)
                    }
                }
                if let mac = json["mac_address"] as? String, !mac.isEmpty {
                    self.targetMacAddress = mac
                    UserDefaults.standard.set(mac, forKey: "aircontrol_saved_mac")
                }
                if let vol = json["volume"] as? Double {
                    self.hostVolume = Float(vol)
                }
                if let natural = json["natural_scroll"] as? Bool {
                    self.isNaturalScroll = natural
                }
            case "pong":
                if let sentAt = (json["client_time"] as? Double) ?? (json["timestamp"] as? Double) {
                    let now = Date().timeIntervalSince1970 * 1000
                    let rtt = Int(now - sentAt)
                    self.latencyMs = max(1, min(rtt, 999))
                }
            case "dock_list":
                if let list = json["apps"] as? [[String: Any]] {
                    self.dockApps = list.map { dict in
                        RemoteApp(
                            bundleId: dict["bundle_id"] as? String ?? "",
                            name: dict["name"] as? String ?? "App",
                            isActive: dict["is_active"] as? Bool ?? (dict["is_active"] as? Int == 1),
                            iconBase64: dict["icon_base64"] as? String
                        )
                    }
                }
            default:
                break
            }
        }
    }

    public func sendHostQuery() {
        sendJson(["type": "host_query"])
    }

    // MARK: - WMM High-Priority Motion Channel

    private func sendMotionPacket(eventType: UInt8, dx: Float, dy: Float, fingers: UInt16 = 1, flags: UInt16 = 0) {
        guard isConnected else { return }

        sequenceNumber = sequenceNumber &+ 1

        var buffer = Data(count: 16)
        buffer.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            ptr.storeBytes(of: UInt8(0xA8), toByteOffset: 0, as: UInt8.self)
            ptr.storeBytes(of: eventType, toByteOffset: 1, as: UInt8.self)
            ptr.storeBytes(of: sequenceNumber.bigEndian, toByteOffset: 2, as: UInt16.self)
            ptr.storeBytes(of: dx.bitPattern.bigEndian, toByteOffset: 4, as: UInt32.self)
            ptr.storeBytes(of: dy.bitPattern.bigEndian, toByteOffset: 8, as: UInt32.self)
            ptr.storeBytes(of: fingers.bigEndian, toByteOffset: 12, as: UInt16.self)
            ptr.storeBytes(of: flags.bigEndian, toByteOffset: 14, as: UInt16.self)
        }

        // Prefer direct WMM-tagged UDP socket over MCSession to avoid AWDL channel-hop stutter
        if let udp = udpConnection {
            udp.send(content: buffer, completion: .idempotent)
        } else if let peer = connectedPeer, session != nil {
            try? session.send(buffer, toPeers: [peer], with: .unreliable)
        }
    }

    public func sendMove(dx: Float, dy: Float) {
        sendMotionPacket(eventType: 0x01, dx: dx, dy: dy, fingers: 1)
    }

    public func sendScroll(dx: Float, dy: Float) {
        sendMotionPacket(eventType: 0x02, dx: dx, dy: dy, fingers: 2)
    }

    public func sendDrag(dx: Float, dy: Float) {
        sendMotionPacket(eventType: 0x03, dx: dx, dy: dy, flags: 0x01)
    }

    public func sendClick(isRight: Bool = false, isDouble: Bool = false) {
        var flags: UInt16 = isRight ? 0x02 : 0x01
        if isDouble { flags |= 0x08 }
        sendMotionPacket(eventType: 0x04, dx: 0, dy: 0, flags: flags)
    }

    public func sendDragRelease() {
        sendMotionPacket(eventType: 0x05, dx: 0, dy: 0)
    }

    // MARK: - Control Channel

    private func sendJson(_ object: [String: Any]) {
        guard isConnected, let data = try? JSONSerialization.data(withJSONObject: object) else { return }

        if let tcp = tcpConnection {
            var length = UInt32(data.count).bigEndian
            var packet = Data(bytes: &length, count: 4)
            packet.append(data)
            tcp.send(content: packet, completion: .contentProcessed { _ in })
        } else if let peer = connectedPeer, session != nil {
            try? session.send(data, toPeers: [peer], with: .reliable)
        }
    }

    private func startPingLoop() {
        stopPingLoop()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            let now = Date().timeIntervalSince1970 * 1000
            self.sendJson(["type": "ping", "client_time": now])
        }
    }

    private func stopPingLoop() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    public func sendTextCommit(_ text: String) {
        sendJson(["type": "text_commit", "text": text])
    }

    public func sendKeyEvent(keyCode: UInt16, action: String = "down", cmd: Bool = false, opt: Bool = false, ctrl: Bool = false, shift: Bool = false) {
        sendJson([
            "type": "key_event",
            "key_code": keyCode,
            "action": action,
            "modifiers": [
                "cmd": cmd,
                "opt": opt,
                "ctrl": ctrl,
                "shift": shift
            ]
        ])
    }

    public func setNaturalScroll(_ enabled: Bool) {
        isNaturalScroll = enabled
        sendJson([
            "type": "settings_update",
            "natural_scroll": enabled
        ])
    }

    public func setVolume(_ volume: Float) {
        hostVolume = volume
        sendJson([
            "type": "media_command",
            "action": "volume_set",
            "value": Double(volume)
        ])
    }

    public func toggleMute() {
        sendJson([
            "type": "media_command",
            "action": "volume_mute_toggle"
        ])
    }

    public func playPause() {
        sendJson([
            "type": "media_command",
            "action": "play_pause"
        ])
    }

    public func nextTrack() {
        sendJson([
            "type": "media_command",
            "action": "next_track"
        ])
    }

    public func prevTrack() {
        sendJson([
            "type": "media_command",
            "action": "prev_track"
        ])
    }

    public func requestDock() {
        sendJson(["type": "dock_get"])
    }

    public func activateApp(bundleId: String) {
        sendJson(["type": "app_activate", "bundle_id": bundleId])
    }

    public func terminateApp(bundleId: String) {
        sendJson(["type": "app_terminate", "bundle_id": bundleId])
    }

    public func lockScreen() {
        sendJson(["type": "power_command", "action": "lock_screen"])
    }

    public func displaySleep() {
        sendJson(["type": "power_command", "action": "display_sleep"])
    }

    public func systemSleep() {
        sendJson(["type": "power_command", "action": "system_sleep"])
    }

    public func shutdown() {
        sendJson(["type": "power_command", "action": "shutdown"])
    }

    public func restart() {
        sendJson(["type": "power_command", "action": "restart"])
    }

    public func sendWakeOnLAN(targetMac: String? = nil, completion: ((Result<Void, Error>) -> Void)? = nil) {
        let macToUse = targetMac ?? self.targetMacAddress
        WakeOnLAN.wake(mac: macToUse, completion: completion)
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
