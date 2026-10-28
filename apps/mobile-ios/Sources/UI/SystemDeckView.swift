import SwiftUI
import UIKit

public struct SystemDeckView: View {
    @ObservedObject var client = MultipeerClient.shared
    @ObservedObject var trackpadSettings = TrackpadSettings.shared

    @State private var showingShutdownAlert: Bool = false
    @State private var showingRestartAlert: Bool = false
    @State private var showingInfoAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""

    @State private var showingMacEditor: Bool = false
    @State private var editableMac: String = ""
    @State private var showingLogSheet: Bool = false

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let notificationHaptic = UINotificationFeedbackGenerator()

    public init() {}

    private func triggerWakeOnLAN() {
        haptic.impactOccurred()
        let mac = client.targetMacAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mac.isEmpty else {
            editableMac = ""
            showingMacEditor = true
            return
        }

        client.sendWakeOnLAN(targetMac: mac) { result in
            switch result {
            case .success:
                notificationHaptic.notificationOccurred(.success)
                alertTitle = "已发送唤醒指令"
                alertMessage = "目标物理地址: \(mac)"
                showingInfoAlert = true
            case .failure(let err):
                notificationHaptic.notificationOccurred(.error)
                alertTitle = "唤醒失败"
                alertMessage = err.localizedDescription
                showingInfoAlert = true
            }
        }
    }

    private func powerPill(icon: String, title: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            haptic.impactOccurred()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isDestructive ? .red : AppTheme.textPrimary)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(isDestructive ? .red : AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(AppTheme.surfaceElevated)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(AppTheme.border)

            VStack(spacing: 14) {
                // Pointer Speed
                HStack(spacing: 12) {
                    Text("指针速度")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textPrimary)

                    Slider(value: $trackpadSettings.sensitivity, in: 0.5...2.5, step: 0.1)
                        .tint(AppTheme.accent)

                    Text(String(format: "%.1fx", trackpadSettings.sensitivity))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(AppTheme.textSecondary)
                        .frame(width: 36, alignment: .trailing)
                }

                // Natural Scroll & Diagnostic Log Button
                HStack(spacing: 12) {
                    Toggle(
                        "自然滚动",
                        isOn: Binding(
                            get: { client.isNaturalScroll },
                            set: { client.setNaturalScroll($0) }
                        )
                    )
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textPrimary)
                    .tint(AppTheme.accent)

                    Button {
                        haptic.impactOccurred()
                        client.requestHostLogs()
                        showingLogSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 12))
                            Text("日志导出")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(AppTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppTheme.surfaceElevated)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                // Compact Power Action Bar
                HStack(spacing: 8) {
                    powerPill(icon: "bolt.fill", title: "唤醒") {
                        triggerWakeOnLAN()
                    }
                    powerPill(icon: "moon.fill", title: "息屏") {
                        client.displaySleep()
                    }
                    powerPill(icon: "powersleep", title: "睡眠") {
                        client.systemSleep()
                    }
                    powerPill(icon: "lock.fill", title: "锁屏") {
                        client.lockScreen()
                    }
                    powerPill(icon: "arrow.clockwise", title: "重启") {
                        showingRestartAlert = true
                    }
                    powerPill(icon: "power", title: "关机", isDestructive: true) {
                        showingShutdownAlert = true
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(height: 195)
            .background(AppTheme.surface)
        }
        .alert(isPresented: $showingInfoAlert) {
            Alert(title: Text(alertTitle), message: Text(alertMessage), dismissButton: .default(Text("好")))
        }
        .confirmationDialog("确定要关机吗？", isPresented: $showingShutdownAlert, titleVisibility: .visible) {
            Button("关机", role: .destructive) {
                client.shutdown()
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("确定要重新启动吗？", isPresented: $showingRestartAlert, titleVisibility: .visible) {
            Button("重新启动", role: .destructive) {
                client.restart()
            }
            Button("取消", role: .cancel) {}
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
        .sheet(isPresented: $showingLogSheet) {
            DiagnosticLogSheet()
        }
    }
}

struct DiagnosticLogSheet: View {
    @ObservedObject var logger = DiagnosticLogger.shared
    @ObservedObject var client = MultipeerClient.shared
    @Environment(\.dismiss) var dismiss
    @State private var copiedToast: Bool = false

    private func shareLogFile() {
        guard let url = logger.writeExportFile() else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            if let pop = av.popoverPresentationController {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            }
            top.present(av, animated: true)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Live Connection Telemetry Summary Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("移动通道: \(client.activeMotionChannelName)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(AppTheme.textPrimary)
                        Spacer()
                        Text("延迟: \(client.latencyMs)ms")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    HStack {
                        Text("控制通道: \(client.activeControlChannelName)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppTheme.textSecondary)
                        Spacer()
                        Text("程序同步: \(logger.lastDockSyncMs)ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppTheme.textSecondary)
                    }
                }
                .padding(12)
                .background(AppTheme.surfaceElevated)

                Divider()

                // Scrollable Monospaced Log View
                ScrollView {
                    Text(logger.buildExportText())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
                .background(Color.white)

                Divider()

                // Action Bar
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = logger.buildExportText()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        copiedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            copiedToast = false
                        }
                    } label: {
                        Text(copiedToast ? "已复制全部日志" : "复制日志")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(AppTheme.accent)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    Button {
                        shareLogFile()
                    } label: {
                        Text("导出文件")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(AppTheme.surfaceElevated)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    Button {
                        logger.clear()
                    } label: {
                        Text("清空")
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .frame(width: 56, height: 40)
                            .background(AppTheme.surfaceElevated)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(AppTheme.surface)
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("刷新") {
                        client.requestHostLogs()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                client.requestHostLogs()
            }
        }
    }
}

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
                Section(header: Text("物理地址 (MAC)")) {
                    TextField("00:00:00:00:00:00", text: $macText)
                        .font(.system(size: 14, design: .monospaced))
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("唤醒设置")
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
                }
            }
        }
    }
}
