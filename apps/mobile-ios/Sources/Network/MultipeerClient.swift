import Foundation
import MultipeerConnectivity
import UIKit
import Combine
import Network

public struct RemoteApp: Identifiable, Hashable {
    public var id: String { bundleId }
    public let bundleId: String
    public let name: String
    public var isActive: Bool
    public var iconBase64: String?

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
    private var udpConnections: [String: NWConnection] = [:]
    private let socketQueue = DispatchQueue(label: "com.aircontrol.client.socket", qos: .userInteractive)

    @Published public var isConnected: Bool = false
    @Published public var isTcpReady: Bool = false
    @Published public var isUdpVerified: Bool = false
    @Published public var udpRttMs: Int = 0
    @Published public var connectedHostName: String = UserDefaults.standard.string(forKey: "aircontrol_saved_host_name") ?? ""
    @Published public var hostIP: String = UserDefaults.standard.string(forKey: "aircontrol_saved_host_ip") ?? ""
    @Published public var candidateHostIPs: [String] = []
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
    private var lastUdpPongTime: TimeInterval = 0
    private var dockRequestTimestampMs: Double = 0
    private var requestedIconBundleIds: Set<String> = []

    // Persistent local app icon cache (bundleId -> compressed 40x40 JPEG Base64)
    private var iconCache: [String: String] = [:]
    private let iconCacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("aircontrol_icon_cache_v2.json")
    }()

    public var cachedIconCount: Int {
        return iconCache.count
    }

    public var activeMotionChannelName: String {
        if isUdpVerified && isTcpReady {
            return "双路竞速 UDP+TCP (\(hostIP))"
        } else if isUdpVerified {
            return "UDP直连 (\(hostIP):8920)"
        } else if isTcpReady {
            return "TCP直连 (\(hostIP):8921)"
        } else if connectedPeer != nil {
            return "MCSession (P2P)"
        } else {
            return "未就绪"
        }
    }

    public var activeControlChannelName: String {
        if isTcpReady {
            return "TCP直连 (\(hostIP):8921)"
        } else if connectedPeer != nil {
            return "MCSession (P2P)"
        } else {
            return "未就绪"
        }
    }

    private override init() {
        super.init()
        loadIconCacheFromDisk()
        setupPeer()
        setupLifecycleObservers()
    }

    private func loadIconCacheFromDisk() {
        guard let data = try? Data(contentsOf: iconCacheURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        self.iconCache = dict
    }

    private func saveIconCacheToDisk() {
        let snapshot = self.iconCache
        DispatchQueue.global(qos: .utility).async { [iconCacheURL] in
            if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
                try? data.write(to: iconCacheURL, options: .atomic)
            }
        }
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
        DiagnosticLogger.shared.log("CONN", "Client start() invoked. savedIP=\(hostIP), isConnected=\(isConnected)")

        // 1. Instant Fast-Path: Immediately dial last known Mac IP if valid LAN IP
        let savedIP = hostIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isValidLanIP(savedIP) && !isTcpReady {
            if !candidateHostIPs.contains(savedIP) {
                candidateHostIPs.append(savedIP)
            }
            connectDirectSockets(host: savedIP, tcpPort: 8921, udpPort: 8920)
        }

        // 2. If Mac is sleeping, silently send a background Wake-on-LAN packet
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

    public static func isValidLanIP(_ ip: String) -> Bool {
        guard !ip.isEmpty && ip != "127.0.0.1" && !ip.hasPrefix("169.254.") && !ip.hasPrefix("198.18.") && !ip.hasPrefix("10.7.") else {
            return false
        }
        return true
    }

    /// Stops background radio scanning once connected so Wi-Fi chip never hops off the main channel
    private func pauseBackgroundScanning() {
        browser?.stopBrowsingForPeers()
        netBrowser?.stop()
        resolvingServices.removeAll()
        isSearching = false
    }

    /// Once Direct LAN TCP or UDP is ready, disconnect MCSession completely
    /// so iOS and macOS shut down awdl0 and stop 100ms AWDL channel hopping!
    private func shutdownRedundantMcSessionIfReady() {
        guard isTcpReady || isUdpVerified else { return }
        pauseBackgroundScanning()
        if connectedPeer != nil {
            DiagnosticLogger.shared.log("CONN", "Direct LAN socket verified -> Disconnecting MCSession to shut down awdl0 radio hopping")
            connectedPeer = nil
            session?.disconnect()
        }
    }

    public func rescan() {
        DiagnosticLogger.shared.log("CONN", "Manual rescan triggered")
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
        for (_, udp) in udpConnections {
            udp.cancel()
        }
        udpConnections.removeAll()
        stopPingLoop()
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        DispatchQueue.main.async {
            self.isConnected = false
            self.isTcpReady = false
            self.isUdpVerified = false
            self.latencyMs = 0
            self.connectedPeer = nil
            self.isSearching = false
        }
    }

    public func connect(to peerID: MCPeerID) {
        DiagnosticLogger.shared.log("MC", "Inviting MCSession peer: \(peerID.displayName)")
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
            DiagnosticLogger.shared.log("SYS", "App entered foreground. Interfaces: \(DiagnosticLogger.describeInterfaces())")
            if !self.isConnected {
                self.start()
            } else {
                self.sendUdpEchoProbe()
                self.sendHostQuery()
                self.requestDock()
                self.startPingLoop()
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            DiagnosticLogger.shared.log("SYS", "App entered background")
            self?.stopPingLoop()
        }
    }

    private func startReconnectMonitor() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isConnected {
                let ip = self.hostIP.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isValidLanIP(ip) && self.tcpConnection == nil {
                    self.connectDirectSockets(host: ip, tcpPort: 8921, udpPort: 8920)
                }
            } else if !self.isUdpVerified {
                self.sendUdpEchoProbe()
            }
        }
    }

    // MARK: - MCNearbyServiceBrowserDelegate

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            DiagnosticLogger.shared.log("MC", "Discovered peer: \(peerID.displayName)")
            if !self.discoveredHosts.contains(peerID) {
                self.discoveredHosts.append(peerID)
            }
            if !self.isConnected && self.connectedPeer == nil && !self.isTcpReady {
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
                DiagnosticLogger.shared.log("MC", "MCSession connected to \(peerID.displayName)")
                self.isConnected = true
                self.connectedPeer = peerID
                self.connectedHostName = peerID.displayName
                UserDefaults.standard.set(peerID.displayName, forKey: "aircontrol_saved_host_name")
                self.pauseBackgroundScanning()
                self.sendHostQuery()
                self.startPingLoop()
                self.requestDock()
            case .notConnected:
                DiagnosticLogger.shared.log("MC", "MCSession notConnected: \(peerID.displayName) (isTcpReady=\(self.isTcpReady))")
                if self.connectedPeer == peerID {
                    self.connectedPeer = nil
                    if !self.isTcpReady {
                        self.isConnected = false
                        self.latencyMs = 0
                        self.stopPingLoop()
                        self.start()
                    }
                }
            case .connecting:
                DiagnosticLogger.shared.log("MC", "MCSession connecting to \(peerID.displayName)...")
            @unknown default:
                break
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            handleReceivedJson(json, type: type, payloadBytes: data.count)
        }
    }

    // MARK: - Direct WMM UDP + TCP_NODELAY Socket Engine (VPN Bypass + Multi-IP Racing)

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.append(service)
        service.resolve(withTimeout: 3.0)
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else { return }
        var resolvedIPs: [String] = []
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

                if Self.isValidLanIP(ipStr) && !resolvedIPs.contains(ipStr) {
                    resolvedIPs.append(ipStr)
                }
            }
        }

        guard let firstIP = resolvedIPs.first else { return }
        DispatchQueue.main.async {
            DiagnosticLogger.shared.log("BONJOUR", "Resolved '\(sender.name)' -> IPs: \(resolvedIPs.joined(separator: ", "))")
            for ip in resolvedIPs {
                if !self.candidateHostIPs.contains(ip) {
                    self.candidateHostIPs.append(ip)
                }
                self.ensureUdpChannel(host: ip, port: 8920)
            }
            if !self.isTcpReady {
                self.connectDirectSockets(host: firstIP, tcpPort: UInt16(sender.port), udpPort: 8920)
            }
        }
    }

    private func ensureUdpChannel(host: String, port: UInt16 = 8920) {
        guard Self.isValidLanIP(host) else { return }
        if udpConnections[host] != nil { return }

        let udpParams = NWParameters.udp
        // Force physical Wi-Fi interface (en0) on iOS, bypassing VPN utun5 (10.7.1.1) and Cellular pdp_ip0!
        udpParams.requiredInterfaceType = .wifi
        udpParams.prohibitedInterfaceTypes = [.other, .cellular]
        udpParams.serviceClass = .interactiveVideo

        let udpEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let udp = NWConnection(to: udpEndpoint, using: udpParams)
        udp.stateUpdateHandler = { [weak self, weak udp] state in
            guard let self = self, let udp = udp else { return }
            if case .ready = state {
                self.receiveUdpEchoLoop(from: udp, host: host)
                self.sendUdpEchoProbe()
            } else if case .failed = state {
                DispatchQueue.main.async {
                    self.udpConnections.removeValue(forKey: host)
                }
            }
        }
        udp.start(queue: socketQueue)
        self.udpConnections[host] = udp
        DiagnosticLogger.shared.log("UDP", "Initialized Wi-Fi Direct UDP channel to \(host):\(port) (utun bypassed)")
    }

    private func sendUdpEchoProbe() {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var probe = Data(count: 16)
        probe.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            ptr.storeBytes(of: UInt8(0xA8), toByteOffset: 0, as: UInt8.self)
            ptr.storeBytes(of: UInt8(0xFE), toByteOffset: 1, as: UInt8.self)
            ptr.storeBytes(of: nowMs.bigEndian, toByteOffset: 8, as: UInt64.self)
        }
        for (_, udp) in udpConnections {
            udp.send(content: probe, completion: .idempotent)
        }
    }

    private func receiveUdpEchoLoop(from connection: NWConnection, host: String) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self = self, let connection = connection, error == nil else { return }
            if let data = content, data.count >= 4, data[0] == 0xA8 {
                let subType = data[1]
                if subType == 0xFD {
                    // 802.11 PM=0 Radio Keep-Awake pulse from Mac during active mouse movement
                    DiagnosticLogger.shared.recordKeepAwakePulse()
                    DispatchQueue.main.async {
                        self.lastUdpPongTime = ProcessInfo.processInfo.systemUptime
                        self.isUdpVerified = true
                    }
                } else if subType == 0xFF && data.count >= 16 {
                    let sentMs = data.withUnsafeBytes { raw -> UInt64 in
                        guard let ptr = raw.baseAddress else { return 0 }
                        return UInt64(bigEndian: ptr.load(fromByteOffset: 8, as: UInt64.self))
                    }
                    let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
                    let rtt = sentMs > 0 && nowMs >= sentMs ? Int(nowMs - sentMs) : 1
                    DispatchQueue.main.async {
                        let wasVerified = self.isUdpVerified
                        self.isUdpVerified = true
                        self.lastUdpPongTime = ProcessInfo.processInfo.systemUptime
                        self.udpRttMs = max(1, min(rtt, 999))
                        self.latencyMs = self.udpRttMs
                        DiagnosticLogger.shared.recordUdpEcho(rttMs: self.udpRttMs)
                        if !wasVerified {
                            DiagnosticLogger.shared.log("UDP", "UDP Direct VERIFIED (\(host):8920, RTT=\(self.udpRttMs)ms)")
                            self.shutdownRedundantMcSessionIfReady()
                        }
                    }
                }
            }
            self.receiveUdpEchoLoop(from: connection, host: host)
        }
    }

    private func connectDirectSockets(host: String, tcpPort: UInt16 = 8921, udpPort: UInt16 = 8920) {
        guard Self.isValidLanIP(host) else { return }
        self.hostIP = host
        UserDefaults.standard.set(host, forKey: "aircontrol_saved_host_ip")

        ensureUdpChannel(host: host, port: udpPort)

        guard tcpConnection == nil else { return }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 3
        let tcpParams = NWParameters(tls: nil, tcp: tcpOptions)
        // Force physical Wi-Fi interface (en0) on iOS, bypassing VPN utun5 and Cellular pdp_ip0!
        tcpParams.requiredInterfaceType = .wifi
        tcpParams.prohibitedInterfaceTypes = [.other, .cellular]
        tcpParams.serviceClass = .interactiveVideo

        let tcpEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: tcpPort)!)
        let tcp = NWConnection(to: tcpEndpoint, using: tcpParams)
        DiagnosticLogger.shared.log("TCP", "Dialing Direct TCP \(host):\(tcpPort) (utun bypassed)...")

        tcp.stateUpdateHandler = { [weak self, weak tcp] state in
            guard let self = self, let tcp = tcp else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    DiagnosticLogger.shared.log("TCP", "Direct TCP READY (\(host):\(tcpPort))")
                    self.isTcpReady = true
                    self.isConnected = true
                    self.hostIP = host
                    UserDefaults.standard.set(host, forKey: "aircontrol_saved_host_ip")
                    self.pauseBackgroundScanning()
                    self.startPingLoop()
                    self.sendJson(["type": "client_hello", "client_name": UIDevice.current.name])
                    self.requestDock()
                    self.sendUdpEchoProbe()
                    self.shutdownRedundantMcSessionIfReady()
                }
                self.receiveTcpStream(from: tcp)
            case .failed(let err):
                DispatchQueue.main.async {
                    DiagnosticLogger.shared.log("TCP", "Direct TCP failed (\(host)): \(err.localizedDescription)")
                    if self.tcpConnection === tcp {
                        self.tcpConnection = nil
                        self.isTcpReady = false
                    }
                    self.tryNextCandidateIP(failedIP: host)
                    if self.connectedPeer == nil && !self.isTcpReady {
                        self.isConnected = false
                    }
                }
            case .cancelled:
                DispatchQueue.main.async {
                    if self.tcpConnection === tcp {
                        self.tcpConnection = nil
                        self.isTcpReady = false
                    }
                    if self.connectedPeer == nil && !self.isTcpReady {
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

    private func tryNextCandidateIP(failedIP: String) {
        guard let idx = candidateHostIPs.firstIndex(of: failedIP), idx + 1 < candidateHostIPs.count else { return }
        let nextIP = candidateHostIPs[idx + 1]
        if Self.isValidLanIP(nextIP) {
            DiagnosticLogger.shared.log("NET", "Trying alternate Mac LAN IP: \(nextIP)")
            connectDirectSockets(host: nextIP, tcpPort: 8921, udpPort: 8920)
        }
    }

    private func receiveTcpStream(from connection: NWConnection) {
        func readNext() {
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] lenData, _, _, error in
                guard let self = self, let connection = connection, let lenBytes = lenData, lenBytes.count == 4, error == nil else {
                    DispatchQueue.main.async {
                        if self?.tcpConnection === connection {
                            self?.tcpConnection = nil
                            self?.isTcpReady = false
                        }
                        if self?.connectedPeer == nil {
                            self?.isConnected = false
                            self?.start()
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
                        self.handleReceivedJson(json, type: type, payloadBytes: data.count)
                    }
                    readNext()
                }
            }
        }
        readNext()
    }

    // MARK: - Unified Packet Dispatch & Receive

    private func handleReceivedJson(_ json: [String: Any], type: String, payloadBytes: Int = 0) {
        DispatchQueue.main.async {
            switch type {
            case "host_ack":
                if let hostName = json["host_name"] as? String {
                    self.connectedHostName = hostName
                    UserDefaults.standard.set(hostName, forKey: "aircontrol_saved_host_name")
                }
                let udpPort = UInt16(json["udp_port"] as? Int ?? 8920)
                let tcpPort = UInt16(json["tcp_port"] as? Int ?? 8921)

                if let ips = json["local_ips"] as? [String] {
                    let valid = ips.filter { Self.isValidLanIP($0) }
                    for ip in valid {
                        if !self.candidateHostIPs.contains(ip) {
                            self.candidateHostIPs.append(ip)
                        }
                        // Open parallel UDP channels to ALL Mac LAN IPs (e.g. en3 Wired Ethernet 192.168.0.103 + en0 Wi-Fi 192.168.0.101)!
                        self.ensureUdpChannel(host: ip, port: udpPort)
                    }
                }
                if let ip = json["local_ip"] as? String, Self.isValidLanIP(ip) {
                    if !self.candidateHostIPs.contains(ip) {
                        self.candidateHostIPs.insert(ip, at: 0)
                    }
                    self.ensureUdpChannel(host: ip, port: udpPort)
                    // Only dial TCP if TCP isn't already connected! Never tear down an already-working en3 TCP connection!
                    if !self.isTcpReady {
                        self.connectDirectSockets(host: ip, tcpPort: tcpPort, udpPort: udpPort)
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
                    let nowMs = Date().timeIntervalSince1970 * 1000
                    let elapsed = self.dockRequestTimestampMs > 0 ? max(1, Int(nowMs - self.dockRequestTimestampMs)) : 1
                    var missingIconBundleIds: [String] = []

                    self.dockApps = list.map { dict in
                        let bid = dict["bundle_id"] as? String ?? ""
                        let name = dict["name"] as? String ?? "App"
                        let active = dict["is_active"] as? Bool ?? (dict["is_active"] as? Int == 1)
                        var icon = dict["icon_base64"] as? String
                        if let provided = icon, !provided.isEmpty {
                            self.iconCache[bid] = provided
                        } else if let cached = self.iconCache[bid] {
                            icon = cached
                        } else if !bid.isEmpty && !self.requestedIconBundleIds.contains(bid) {
                            missingIconBundleIds.append(bid)
                            self.requestedIconBundleIds.insert(bid)
                        }
                        return RemoteApp(bundleId: bid, name: name, isActive: active, iconBase64: icon)
                    }

                    DiagnosticLogger.shared.recordDockSync(
                        appCount: self.dockApps.count,
                        elapsedMs: elapsed,
                        payloadBytes: payloadBytes
                    )

                    if !missingIconBundleIds.isEmpty {
                        self.sendJson(["type": "dock_icons_get", "bundle_ids": missingIconBundleIds])
                    }
                }

            case "dock_icons":
                if let iconsDict = json["icons"] as? [String: String], !iconsDict.isEmpty {
                    for (bid, base64) in iconsDict {
                        self.iconCache[bid] = base64
                        self.requestedIconBundleIds.remove(bid)
                    }
                    self.dockApps = self.dockApps.map { app in
                        var copy = app
                        if let updated = iconsDict[app.bundleId] {
                            copy.iconBase64 = updated
                        }
                        return copy
                    }
                    self.saveIconCacheToDisk()
                    DiagnosticLogger.shared.log("DOCK", "Cached \(iconsDict.count) compressed app icons (\(payloadBytes) bytes)")
                }

            case "dock_active":
                if let activeBid = json["bundle_id"] as? String {
                    self.dockApps = self.dockApps.map { app in
                        var copy = app
                        copy.isActive = (app.bundleId == activeBid)
                        return copy
                    }
                }

            case "host_logs_reply":
                let summary = json["summary"] as? [String: Any] ?? [:]
                let lines = json["lines"] as? [String] ?? []
                DiagnosticLogger.shared.updateHostLogs(summary: summary, lines: lines)
                DiagnosticLogger.shared.log("SYS", "Received \(lines.count) diagnostic log lines from Mac host")

            default:
                break
            }
        }
    }

    public func sendHostQuery() {
        sendJson(["type": "host_query"])
    }

    public func requestHostLogs() {
        sendJson(["type": "host_logs_get"])
    }

    // MARK: - Multi-Path Racing Motion Channel (Wired Ethernet UDP + Wi-Fi UDP + TCP_NODELAY)

    private func sendMotionPacket(eventType: UInt8, dx: Float, dy: Float, fingers: UInt16 = 1, flags: UInt16 = 0, isStrokeStart: Bool = false) {
        guard isConnected else { return }

        sequenceNumber = sequenceNumber &+ 1
        var finalFlags = flags
        if isStrokeStart {
            finalFlags |= 0x80
        }

        var buffer = Data(count: 16)
        buffer.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            ptr.storeBytes(of: UInt8(0xA8), toByteOffset: 0, as: UInt8.self)
            ptr.storeBytes(of: eventType, toByteOffset: 1, as: UInt8.self)
            ptr.storeBytes(of: sequenceNumber.bigEndian, toByteOffset: 2, as: UInt16.self)
            ptr.storeBytes(of: dx.bitPattern.bigEndian, toByteOffset: 4, as: UInt32.self)
            ptr.storeBytes(of: dy.bitPattern.bigEndian, toByteOffset: 8, as: UInt32.self)
            ptr.storeBytes(of: fingers.bigEndian, toByteOffset: 12, as: UInt16.self)
            ptr.storeBytes(of: finalFlags.bigEndian, toByteOffset: 14, as: UInt16.self)
        }

        var sentViaLan = false

        // 1. Blast across ALL active UDP LAN channels (e.g. en3 Wired Ethernet 192.168.0.103 + en0 Wi-Fi 192.168.0.101)
        if !udpConnections.isEmpty {
            for (_, udp) in udpConnections {
                udp.send(content: buffer, completion: .idempotent)
            }
            sentViaLan = true
        }

        // 2. Simultaneously race on the TCP_NODELAY socket (192.168.0.103:8921) — Mac deduplicates by sequenceNumber!
        if isTcpReady, let tcp = tcpConnection {
            var length = UInt32(16).bigEndian
            var tcpPacket = Data(bytes: &length, count: 4)
            tcpPacket.append(buffer)
            tcp.send(content: tcpPacket, completion: .idempotent)
            sentViaLan = true
        }

        if sentViaLan {
            DiagnosticLogger.shared.recordMotionTx(
                viaUdp: true,
                activeChannelDesc: "MultiPath(\(hostIP))",
                isStrokeStart: isStrokeStart
            )
        } else if let peer = connectedPeer, session != nil {
            try? session.send(buffer, toPeers: [peer], with: .unreliable)
            DiagnosticLogger.shared.recordMotionTx(
                viaUdp: false,
                activeChannelDesc: "MCSession",
                isStrokeStart: isStrokeStart
            )
        }
    }

    public func sendMove(dx: Float, dy: Float, isStrokeStart: Bool = false) {
        sendMotionPacket(eventType: 0x01, dx: dx, dy: dy, fingers: 1, isStrokeStart: isStrokeStart)
    }

    public func sendScroll(dx: Float, dy: Float, isStrokeStart: Bool = false) {
        sendMotionPacket(eventType: 0x02, dx: dx, dy: dy, fingers: 2, isStrokeStart: isStrokeStart)
    }

    public func sendDrag(dx: Float, dy: Float, isStrokeStart: Bool = false) {
        sendMotionPacket(eventType: 0x03, dx: dx, dy: dy, flags: 0x01, isStrokeStart: isStrokeStart)
    }

    public func sendClick(isRight: Bool = false, isDouble: Bool = false) {
        var flags: UInt16 = isRight ? 0x02 : 0x01
        if isDouble { flags |= 0x08 }
        sendMotionPacket(eventType: 0x04, dx: 0, dy: 0, flags: flags, isStrokeStart: true)
    }

    public func sendDragRelease() {
        sendMotionPacket(eventType: 0x05, dx: 0, dy: 0, isStrokeStart: true)
    }

    // MARK: - Control Channel

    private func sendJson(_ object: [String: Any]) {
        guard isConnected, let data = try? JSONSerialization.data(withJSONObject: object) else { return }

        if isTcpReady, let tcp = tcpConnection {
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
            self.sendUdpEchoProbe()

            if self.isUdpVerified && (ProcessInfo.processInfo.systemUptime - self.lastUdpPongTime) > 5.0 {
                self.isUdpVerified = false
            }
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
        dockRequestTimestampMs = Date().timeIntervalSince1970 * 1000
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
