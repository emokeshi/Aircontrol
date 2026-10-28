import Foundation
import Network

public final class UpdateServer: @unchecked Sendable {
    public static let shared = UpdateServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.aircontrol.update.server", qos: .utility)

    public private(set) var isRunning: Bool = false
    public var port: UInt16 = 8923

    private init() {}

    public func start(port: UInt16 = 8923) throws {
        self.port = port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.isRunning = true
            case .failed(let err):
                self.isRunning = false
                print("[UpdateServer] Failed: \(err)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] content, _, _, error in
            guard let self = self, let connection = connection, let data = content else { return }
            if let requestString = String(data: data, encoding: .utf8) {
                self.respondToHttp(request: requestString, connection: connection)
            }
        }
    }

    private func findIpaPath() -> String? {
        let possiblePaths = [
            Bundle.main.bundlePath + "/../../../dist/AirControl.ipa",
            Bundle.main.bundlePath + "/../../dist/AirControl.ipa",
            Bundle.main.bundlePath + "/../dist/AirControl.ipa",
            FileManager.default.currentDirectoryPath + "/dist/AirControl.ipa",
            FileManager.default.currentDirectoryPath + "/apps/mobile-ios/build/AirControl.ipa",
            "/Users/aaron/Documents/antigravity/nifty-hawking/dist/AirControl.ipa"
        ]

        for p in possiblePaths {
            let standard = (p as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: standard) {
                return standard
            }
        }
        return nil
    }

    private func respondToHttp(request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            connection.cancel()
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad Request".utf8), connection: connection)
            return
        }

        let path = parts[1]

        if path == "/version.json" {
            let info: [String: Any] = [
                "version": "1.2.0",
                "build": 3,
                "name": "AirControl",
                "ipa_endpoint": "/AirControl.ipa",
                "release_notes": "基于 Apple 原生无线对等技术 (MultipeerConnectivity) 彻底解决断连与延迟；120Hz 硬件事件流消除卡顿；纯白极简控制中心；应用内一键下载与 SideStore 原位覆盖升级"
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: info) {
                sendResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: jsonData, connection: connection)
            }
        } else if path == "/AirControl.ipa" {
            if let ipaPath = findIpaPath(), let ipaData = try? Data(contentsOf: URL(fileURLWithPath: ipaPath)) {
                sendResponse(
                    status: "200 OK",
                    contentType: "application/octet-stream",
                    extraHeaders: "Content-Disposition: attachment; filename=\"AirControl.ipa\"\r\n",
                    body: ipaData,
                    connection: connection
                )
            } else {
                sendResponse(status: "404 Not Found", contentType: "text/plain", body: Data("AirControl.ipa not found on host".utf8), connection: connection)
            }
        } else if path == "/source.json" {
            // SideStore / AltStore compatible source
            let source: [String: Any] = [
                "name": "AirControl Local Repo",
                "identifier": "com.aircontrol.local",
                "apps": [
                    [
                        "name": "AirControl",
                        "bundleIdentifier": "com.aircontrol.mobile",
                        "version": "1.2.0",
                        "versionDate": "2026-10-28",
                        "versionDescription": "Apple原生对等互联直连、120Hz硬件事件流、纯白极简控制中心",
                        "downloadURL": "http://\(AppState.shared.localIP):\(port)/AirControl.ipa",
                        "localizedDescription": "Apple原生对等互联直连、120Hz硬件事件流、纯白极简控制中心",
                        "iconURL": "https://raw.githubusercontent.com/emokeshi/Aircontrol/main/apps/mobile-ios/AppIcon.png",
                        "tintColor": "007AFF",
                        "size": 216000
                    ]
                ]
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: source) {
                sendResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: jsonData, connection: connection)
            }
        } else {
            let localIP = AppState.shared.localIP
            let downloadUrl = "http://\(localIP):\(port)/AirControl.ipa"
            let sideStoreUrl = "sidestore://install?url=" + (downloadUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? downloadUrl)

            let html = """
            <!DOCTYPE html>
            <html lang="zh-CN">
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
                <title>AirControl 极速安装与更新</title>
                <style>
                    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
                        background: #F8F9FA;
                        margin: 0;
                        padding: 32px 20px;
                        color: #1C1C1E;
                        display: flex;
                        justify-content: center;
                    }
                    .container {
                        max-width: 440px;
                        width: 100%;
                        background: #FFFFFF;
                        border-radius: 20px;
                        padding: 28px 24px;
                        border: 1px solid #E5E5EA;
                        box-shadow: 0 4px 20px rgba(0,0,0,0.03);
                    }
                    .badge {
                        display: inline-block;
                        padding: 4px 10px;
                        background: #E8F2FF;
                        color: #007AFF;
                        font-size: 12px;
                        font-weight: 600;
                        border-radius: 12px;
                        margin-bottom: 12px;
                    }
                    h1 {
                        font-size: 22px;
                        font-weight: 700;
                        margin: 0 0 8px 0;
                        letter-spacing: -0.3px;
                    }
                    p.desc {
                        font-size: 13px;
                        color: #8E8E93;
                        line-height: 1.5;
                        margin: 0 0 24px 0;
                    }
                    .btn-group {
                        display: flex;
                        flex-direction: column;
                        gap: 12px;
                    }
                    .btn {
                        display: block;
                        text-align: center;
                        padding: 14px 16px;
                        border-radius: 14px;
                        font-size: 15px;
                        font-weight: 600;
                        text-decoration: none;
                        transition: opacity 0.2s;
                    }
                    .btn-primary {
                        background: #007AFF;
                        color: #FFFFFF;
                    }
                    .btn-secondary {
                        background: #F2F2F7;
                        color: #1C1C1E;
                    }
                    .info-box {
                        margin-top: 24px;
                        padding: 14px;
                        background: #F9F9FB;
                        border-radius: 12px;
                        font-size: 12px;
                        color: #636366;
                        line-height: 1.6;
                    }
                </style>
            </head>
            <body>
                <div class="container">
                    <span class="badge">最新版本 v1.2.0 (Build 3)</span>
                    <h1>AirControl for iOS</h1>
                    <p class="desc">基于 Apple 原生无线对等互联 (MultipeerConnectivity) 与 120Hz 硬件事件流打造，告别跳帧与延迟。</p>
                    
                    <div class="btn-group">
                        <a href="\(sideStoreUrl)" class="btn btn-primary">SideStore 一键原位升级 (推荐)</a>
                        <a href="/AirControl.ipa" class="btn btn-secondary">直接下载 AirControl.ipa</a>
                    </div>

                    <div class="info-box">
                        <b>安装提示：</b><br>
                        1. 推荐使用 <b>SideStore 原位升级</b>，不消耗免费开发者 3 个应用名额。<br>
                        2. 如已安装 TrollStore，下载 IPA 后点击分享即可一键免签安装。
                    </div>
                </div>
            </body>
            </html>
            """
            sendResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8), connection: connection)
        }
    }

    private func sendResponse(status: String, contentType: String, extraHeaders: String = "", body: Data, connection: NWConnection) {
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extraHeaders)\r\n"
        var packet = Data(headers.utf8)
        packet.append(body)

        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
