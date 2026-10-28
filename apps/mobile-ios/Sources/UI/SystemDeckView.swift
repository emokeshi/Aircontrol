import SwiftUI
import UIKit

// MARK: - In-App Background IPA Downloader

public final class IPADownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = IPADownloader()

    @Published public var isDownloading: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var downloadedBytes: Int64 = 0
    @Published public var totalBytes: Int64 = 0
    @Published public var downloadedURL: URL? = nil
    @Published public var errorMessage: String? = nil

    private var downloadTask: URLSessionDownloadTask?

    public func startDownload(from url: URL) {
        isDownloading = true
        progress = 0.0
        downloadedBytes = 0
        totalBytes = 0
        downloadedURL = nil
        errorMessage = nil

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.downloadTask(with: url)
        self.downloadTask = task
        task.resume()
    }

    public func cancel() {
        downloadTask?.cancel()
        isDownloading = false
        progress = 0.0
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dest = docs.appendingPathComponent("AirControl.ipa")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async {
                self.isDownloading = false
                self.progress = 1.0
                self.downloadedURL = dest
            }
        } catch {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.errorMessage = "保存安装包失败: \(error.localizedDescription)"
            }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            self.downloadedBytes = totalBytesWritten
            self.totalBytes = totalBytesExpectedToWrite
            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.errorMessage = "下载失败: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - System Deck View (Apple Minimalist White)

public struct SystemDeckView: View {
    @ObservedObject var client = MultipeerClient.shared
    @ObservedObject var downloader = IPADownloader.shared

    // Confirmation & Message Alerts
    @State private var showingShutdownAlert: Bool = false
    @State private var showingRestartAlert: Bool = false
    @State private var showingInfoAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""

    // MAC Address Editor Modal
    @State private var showingMacEditor: Bool = false
    @State private var editableMac: String = ""

    // WoL Sending feedback state
    @State private var isSendingWol: Bool = false

    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let notificationHaptic = UINotificationFeedbackGenerator()

    public static let githubSourceURL = "https://raw.githubusercontent.com/emokeshi/Aircontrol/main/source.json"
    public static let githubLatestIpaURL = "https://github.com/emokeshi/Aircontrol/releases/latest/download/AirControl.ipa"

    public init() {}

    private var localUpdateURL: URL? {
        let ip = client.hostIP.isEmpty ? "127.0.0.1" : client.hostIP
        return URL(string: "http://\(ip):\(client.hostUpdatePort)/AirControl.ipa")
    }

    private func presentShareSheet(url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        topVC.present(activityVC, animated: true)
    }

    private func triggerWakeOnLAN() {
        haptic.impactOccurred()
        let mac = client.targetMacAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mac.isEmpty else {
            editableMac = ""
            showingMacEditor = true
            return
        }

        isSendingWol = true
        client.sendWakeOnLAN(targetMac: mac) { result in
            isSendingWol = false
            switch result {
            case .success:
                notificationHaptic.notificationOccurred(.success)
                alertTitle = "唤醒魔术包已广播"
                alertMessage = "已向局域网广播 WoL 魔术包 (目标 MAC: \(mac))。\n若电脑处于睡眠待机状态，将在 1 秒内被唤醒。"
                showingInfoAlert = true
            case .failure(let err):
                notificationHaptic.notificationOccurred(.error)
                alertTitle = "唤醒失败"
                alertMessage = err.localizedDescription
                showingInfoAlert = true
            }
        }
    }

    private func openSideStoreSource() {
        haptic.impactOccurred()
        let sourceUrl = Self.githubSourceURL
        let scheme = "sidestore://source?url=" + (sourceUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sourceUrl)
        if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let webUrl = URL(string: sourceUrl) {
            UIApplication.shared.open(webUrl)
        }
    }

    private func openSideStoreInstall(urlStr: String) {
        haptic.impactOccurred()
        let scheme = "sidestore://install?url=" + (urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlStr)
        if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let directUrl = URL(string: urlStr) {
            UIApplication.shared.open(directUrl)
        }
    }

    private func systemRow(icon: String, title: String, subtitle: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            haptic.impactOccurred()
            action()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppTheme.surfaceElevated)
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundColor(isDestructive ? .red : AppTheme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isDestructive ? .red : AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textTertiary)
            }
            .padding(14)
            .background(AppTheme.surface)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Connection & Host State Summary
                HStack(spacing: 12) {
                    Image(systemName: client.isConnected ? "checkmark.circle.fill" : "moon.stars.fill")
                        .font(.system(size: 22))
                        .foregroundColor(client.isConnected ? AppTheme.success : AppTheme.warning)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(client.isConnected ? "已直连至 \(client.connectedHostName)" : (client.targetMacAddress.isEmpty ? "未连接电脑" : "电脑未连接 / 息屏待机中"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.textPrimary)

                        if !client.targetMacAddress.isEmpty {
                            Text("已记住网卡 MAC: \(client.targetMacAddress)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(AppTheme.textSecondary)
                        } else {
                            Text("连上 Mac 后将自动记住网卡物理 MAC 地址")
                                .font(.system(size: 11))
                                .foregroundColor(AppTheme.textSecondary)
                        }
                    }

                    Spacer()

                    Button {
                        editableMac = client.targetMacAddress
                        showingMacEditor = true
                    } label: {
                        Image(systemName: "slider.horizontal.2.square")
                            .font(.system(size: 18))
                            .foregroundColor(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(AppTheme.surfaceElevated)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.border, lineWidth: 1)
                )

                // Hero Power Section: Wake-on-LAN & Sleep Controls
                VStack(alignment: .leading, spacing: 8) {
                    Text("电源与休眠控制")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                        .padding(.horizontal, 4)

                    // Hero WoL Wake-up Button
                    Button {
                        triggerWakeOnLAN()
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.orange.opacity(0.12))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.orange)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(isSendingWol ? "正在唤醒..." : "局域网唤醒开机 (Wake-on-LAN)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(AppTheme.textPrimary)
                                Text("向广播地址发送魔术包，电视旁睡眠待机 1 秒瞬时唤醒")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppTheme.textSecondary)
                            }

                            Spacer()

                            Image(systemName: "power")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.orange)
                        }
                        .padding(14)
                        .background(AppTheme.surface)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)

                    // Sleep / Display Controls
                    systemRow(
                        icon: "moon.fill",
                        title: "息屏休眠 (睡眠显示器)",
                        subtitle: "立即熄灭电视或外接屏幕背光，主机保持后台就绪",
                        action: { client.displaySleep() }
                    )

                    systemRow(
                        icon: "powersleep",
                        title: "系统低功耗休眠 (System Sleep)",
                        subtitle: "进入 0.5W 超低待机状态，后续可通过手机 WoL 瞬间唤醒",
                        action: { client.systemSleep() }
                    )

                    systemRow(
                        icon: "lock.fill",
                        title: "立即锁定屏幕",
                        subtitle: "锁定 macOS 系统桌面，保护数据安全",
                        action: { client.lockScreen() }
                    )
                }

                // Advanced Power Controls (关机与重启)
                VStack(alignment: .leading, spacing: 8) {
                    Text("高级系统电源")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                        .padding(.horizontal, 4)

                    systemRow(
                        icon: "arrow.clockwise.circle.fill",
                        title: "系统重启 (Restart)",
                        subtitle: "通过 macOS 系统服务安全重启电脑",
                        isDestructive: false,
                        action: { showingRestartAlert = true }
                    )

                    systemRow(
                        icon: "power.circle.fill",
                        title: "彻底关机 (Shutdown)",
                        subtitle: "通过 macOS 系统服务彻底安全切断电脑电源",
                        isDestructive: true,
                        action: { showingShutdownAlert = true }
                    )
                }

                // In-App Update & SideStore Community Repo Center
                VStack(alignment: .leading, spacing: 8) {
                    Text("GitHub 社区源与更新中心")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                        .padding(.horizontal, 4)

                    // Downloader Progress
                    if downloader.isDownloading {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("正在极速下载最新 IPA 安装包...")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(AppTheme.textPrimary)
                                Spacer()
                                Text("\(Int(downloader.progress * 100))%")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(AppTheme.accent)
                            }

                            ProgressView(value: downloader.progress)
                                .tint(AppTheme.accent)

                            HStack {
                                if downloader.totalBytes > 0 {
                                    let mbDownloaded = Double(downloader.downloadedBytes) / 1024.0 / 1024.0
                                    let mbTotal = Double(downloader.totalBytes) / 1024.0 / 1024.0
                                    Text(String(format: "%.1f MB / %.1f MB", mbDownloaded, mbTotal))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(AppTheme.textTertiary)
                                }
                                Spacer()
                                Button("取消") {
                                    downloader.cancel()
                                }
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                            }
                        }
                        .padding(14)
                        .background(AppTheme.surface)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(AppTheme.accent, lineWidth: 1.5)
                        )
                    }

                    // Download Ready Card
                    if let fileURL = downloader.downloadedURL {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(AppTheme.success)
                            Text("最新 IPA 安装包已准备就绪")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(AppTheme.textPrimary)
                            Spacer()
                            Button("打开 / 导出") {
                                presentShareSheet(url: fileURL)
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(AppTheme.accent)
                        }
                        .padding(12)
                        .background(AppTheme.accentLight.opacity(0.3))
                        .cornerRadius(10)
                    }

                    systemRow(
                        icon: "plus.square.fill.on.square.fill",
                        title: "一键添加源至 SideStore",
                        subtitle: "将 GitHub 社区源添加至 SideStore，后续直接原位检测更新",
                        action: { openSideStoreSource() }
                    )

                    systemRow(
                        icon: "arrow.down.app.fill",
                        title: "SideStore 原位安装升级 (云端最新)",
                        subtitle: "通过 SideStore 直接拉取 GitHub 最新版本原位覆盖，无需消耗 3-App 额度",
                        action: { openSideStoreInstall(urlStr: Self.githubLatestIpaURL) }
                    )

                    systemRow(
                        icon: "arrow.down.circle.fill",
                        title: "应用内直接下载 IPA",
                        subtitle: "下载至本地沙盒，可一键发送至 TrollStore、AltStore 或系统文件",
                        action: {
                            if let localUrl = localUpdateURL, client.isConnected {
                                downloader.startDownload(from: localUrl)
                            } else if let cloudUrl = URL(string: Self.githubLatestIpaURL) {
                                downloader.startDownload(from: cloudUrl)
                            }
                        }
                    )

                    if client.isConnected && !client.hostIP.isEmpty {
                        systemRow(
                            icon: "wifi",
                            title: "SideStore 局域网离线更新 (Mac 托管)",
                            subtitle: "从 Mac 8923 端口离线极速安装，无互联网亦可原位升级",
                            action: {
                                if let url = localUpdateURL {
                                    openSideStoreInstall(urlStr: url.absoluteString)
                                }
                            }
                        )
                    }
                }

                // Version Footer
                VStack(spacing: 4) {
                    Text("AirControl v1.2.0")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.textTertiary)
                    Text("极速直连 · 触控与电源管理")
                        .font(.system(size: 10))
                        .foregroundColor(AppTheme.textTertiary)
                }
                .padding(.top, 8)
            }
            .padding(16)
        }
        .alert(isPresented: $showingInfoAlert) {
            Alert(title: Text(alertTitle), message: Text(alertMessage), dismissButton: .default(Text("好")))
        }
        .confirmationDialog("确定要彻底关闭电脑吗？", isPresented: $showingShutdownAlert, titleVisibility: .visible) {
            Button("彻底关机", role: .destructive) {
                client.shutdown()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("电脑关机后如断开电源将无法远程唤醒，请确认所有未保存工作已保存。")
        }
        .confirmationDialog("确定要重启电脑吗？", isPresented: $showingRestartAlert, titleVisibility: .visible) {
            Button("重新启动", role: .destructive) {
                client.restart()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重启后需等待系统就绪后方可再次连上。")
        }
        .sheet(isPresented: $showingMacEditor) {
            MacAddressEditorSheet(
                currentMac: client.targetMacAddress,
                onSave: { newMac in
                    client.targetMacAddress = newMac
                    UserDefaults.standard.set(newMac, forKey: "aircontrol_saved_mac")
                }
            )
        }
    }
}

// MARK: - MAC Address Editor Sheet

struct MacAddressEditorSheet: View {
    @State var macText: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) var dismiss

    init(currentMac: String, onSave: @escaping (String) -> Void) {
        self._macText = State(initialValue: currentMac)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("目标电脑网卡物理 MAC 地址")) {
                    TextField("如 3C:06:30:AA:BB:CC", text: $macText)
                        .font(.system(size: 14, design: .monospaced))
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                }

                Section(footer: Text("提示：连接过一次 Mac 后系统会自动同步网卡 MAC。也可在 Mac 系统设置 -> 网络 -> 详细信息 -> 硬件中查看物理 MAC 地址。")) {
                    EmptyView()
                }
            }
            .navigationTitle("唤醒网卡地址设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        onSave(macText.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .bold))
                }
            }
        }
    }
}
