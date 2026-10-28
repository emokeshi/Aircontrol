import Foundation
import AppKit

public final class Updater: ObservableObject, @unchecked Sendable {
    public static let shared = Updater()

    @Published public var isChecking: Bool = false
    @Published public var updateAvailable: Bool = false
    @Published public var latestVersion: String = "1.2.0"
    @Published public var statusMessage: String = "当前已是最新版本"

    public let currentVersion: String = "1.2.0"

    private init() {}

    public func checkForUpdates(showPromptIfLatest: Bool = false) {
        isChecking = true
        statusMessage = "正在检查更新..."

        // Query GitHub Releases endpoint
        let updateUrl = URL(string: "https://api.github.com/repos/emokeshi/Aircontrol/releases/latest")!
        var request = URLRequest(url: updateUrl, timeoutInterval: 5)
        request.setValue("AirControl/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false

                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String {

                    let remoteVer = tagName.replacingOccurrences(of: "v", with: "")
                    self.latestVersion = remoteVer

                    if remoteVer.compare(self.currentVersion, options: .numeric) == .orderedDescending {
                        self.updateAvailable = true
                        self.statusMessage = "发现新版本: v\(remoteVer)"
                    } else {
                        self.updateAvailable = false
                        self.statusMessage = "当前已是最新版本 (v\(self.currentVersion))"
                    }
                } else {
                    // Fallback to current version status
                    self.updateAvailable = false
                    self.statusMessage = "已是最新版本 (v\(self.currentVersion))"
                }
            }
        }.resume()
    }
}
