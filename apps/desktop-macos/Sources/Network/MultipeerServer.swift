import Foundation
import MultipeerConnectivity
import AppKit

public final class MultipeerServer: NSObject, @unchecked Sendable, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate {
    public static let shared = MultipeerServer()

    private let serviceType = "aircontrol-p2p"
    private var myPeerID: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!

    public private(set) var isRunning: Bool = false

    private override init() {
        super.init()
    }

    public func start() {
        stop()

        let hostName = Host.current().localizedName ?? "Mac"
        myPeerID = MCPeerID(displayName: hostName)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self

        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: ["ver": "2.0"], serviceType: serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()

        isRunning = true
    }

    public func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session?.disconnect()
        session = nil
        isRunning = false
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                // Stop advertising while connected to prevent awdl0 background channel scanning jitter
                self.advertiser?.stopAdvertisingPeer()
                AppState.shared.connectedClient = peerID.displayName
                self.sendHostAck(to: peerID)
                self.pushRunningDockApps(to: peerID)
            case .notConnected:
                if self.session?.connectedPeers.isEmpty ?? true {
                    self.advertiser?.startAdvertisingPeer()
                    if AppState.shared.connectedClient == peerID.displayName {
                        AppState.shared.connectedClient = nil
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
        if data.count >= 16, data[0] == 0xA8 {
            SocketServer.shared.processMotionPacket(data)
            return
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            processJsonMessage(json, type: type, from: peerID)
        }
    }

    private func processJsonMessage(_ json: [String: Any], type: String, from peerID: MCPeerID) {
        switch type {
        case "ping":
            let clientTime = json["client_time"] ?? json["timestamp"] ?? 0.0
            sendJson(["type": "pong", "client_time": clientTime], to: peerID)

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
            pushRunningDockApps(to: peerID)

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

        case "host_query":
            sendHostAck(to: peerID)
            pushRunningDockApps(to: peerID)

        default:
            break
        }
    }

    private func sendHostAck(to peerID: MCPeerID) {
        let ack: [String: Any] = [
            "type": "host_ack",
            "host_name": Host.current().localizedName ?? "Mac",
            "os": "macOS",
            "ver": "2.0",
            "udp_port": Int(SocketServer.shared.udpPort),
            "local_ip": AppState.shared.localIP,
            "mac_address": AppState.shared.macAddress,
            "volume": Double(SystemController.shared.getMasterVolume()),
            "natural_scroll": InputSimulator.shared.isNaturalScroll,
            "power_state": "awake"
        ]
        sendJson(ack, to: peerID)
    }

    public func broadcastDockApps() {
        guard let peers = session?.connectedPeers, !peers.isEmpty else { return }
        for peer in peers {
            pushRunningDockApps(to: peer)
        }
    }

    private func pushRunningDockApps(to peerID: MCPeerID) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
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
            self.sendJson(["type": "dock_list", "apps": appDicts], to: peerID)
        }
    }

    public func sendJson(_ object: [String: Any], to peerID: MCPeerID? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        if let target = peerID {
            try? session.send(data, toPeers: [target], with: .reliable)
        } else if let peers = session?.connectedPeers, !peers.isEmpty {
            try? session.send(data, toPeers: peers, with: .reliable)
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
