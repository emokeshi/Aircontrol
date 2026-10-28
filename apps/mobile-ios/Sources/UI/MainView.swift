import SwiftUI
import UIKit
import MultipeerConnectivity

public struct MainView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var client = MultipeerClient.shared

    @State private var showingPowerSheet: Bool = false
    @State private var showingShutdownConfirm: Bool = false
    @State private var showingRestartConfirm: Bool = false
    @State private var powerAlertTitle: String = ""
    @State private var powerAlertMsg: String = ""
    @State private var showingPowerAlert: Bool = false

    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let notifyHaptic = UINotificationFeedbackGenerator()

    public init() {}

    private func triggerWake() {
        haptic.impactOccurred()
        let mac = client.targetMacAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mac.isEmpty else {
            powerAlertTitle = "未设置网卡 MAC"
            powerAlertMsg = "请在「系统」页面中手动输入电脑的物理 MAC 地址，或先直连一次 Mac 进行自动记住。"
            showingPowerAlert = true
            return
        }
        client.sendWakeOnLAN(targetMac: mac) { res in
            switch res {
            case .success:
                notifyHaptic.notificationOccurred(.success)
                powerAlertTitle = "唤醒魔术包已广播"
                powerAlertMsg = "已向局域网广播 WoL 魔术包 (目标 MAC: \(mac))。\n若电脑处于睡眠待机状态，将在 1 秒内被唤醒。"
                showingPowerAlert = true
            case .failure(let err):
                notifyHaptic.notificationOccurred(.error)
                powerAlertTitle = "唤醒失败"
                powerAlertMsg = err.localizedDescription
                showingPowerAlert = true
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Navigation & Auto-Discovery Header
            HStack(spacing: 8) {
                Button {
                    appState.showHostPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 13))
                            .foregroundColor(client.isConnected ? AppTheme.accent : AppTheme.textSecondary)

                        Text(client.isConnected ? client.connectedHostName : (client.isSearching ? "正在搜索局域网 Mac..." : "未发现电脑"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.textPrimary)
                            .lineLimit(1)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(AppTheme.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppTheme.surfaceElevated)
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                // Main View Power / WoL Button (优先提供「唤醒开机」与「息屏休眠」)
                Button {
                    showingPowerSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .bold))
                        if !client.isConnected {
                            Text("唤醒")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundColor(client.isConnected ? AppTheme.accent : .orange)
                    .padding(.horizontal, client.isConnected ? 8 : 10)
                    .padding(.vertical, 5)
                    .background(client.isConnected ? AppTheme.surfaceElevated : Color.orange.opacity(0.12))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(client.isConnected ? AppTheme.border : Color.orange.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Latency Badge
                HStack(spacing: 5) {
                    Circle()
                        .fill(client.isConnected ? AppTheme.success : AppTheme.warning)
                        .frame(width: 6, height: 6)

                    Text(client.isConnected ? "\(client.latencyMs)ms" : "离线")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(client.isConnected ? AppTheme.accent : AppTheme.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(client.isConnected ? AppTheme.accentLight : AppTheme.surfaceElevated)
                .cornerRadius(12)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(AppTheme.surface)

            Divider()
                .background(AppTheme.borderSubtle)

            // Minimalist Tab Selector (全中文)
            HStack(spacing: 0) {
                tabButton(title: "触控板", icon: "hand.tap.fill", index: 0)
                tabButton(title: "键盘", icon: "keyboard.fill", index: 1)
                tabButton(title: "媒体", icon: "play.tv.fill", index: 2)
                tabButton(title: "系统", icon: "slider.horizontal.3", index: 3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(AppTheme.surface)

            Divider()
                .background(AppTheme.borderSubtle)

            // Tab Content
            Group {
                switch appState.selectedTab {
                case 0:
                    TrackpadView()
                case 1:
                    KeyboardDeckView()
                case 2:
                    MediaDeckView()
                default:
                    SystemDeckView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom Dock
            DockView()
        }
        .background(AppTheme.background)
        .preferredColorScheme(.light)
        .sheet(isPresented: $appState.showHostPicker) {
            HostPickerSheet()
        }
        .confirmationDialog("电源与休眠管理", isPresented: $showingPowerSheet, titleVisibility: .visible) {
            Button("⚡ 局域网唤醒开机 (Wake-on-LAN)") {
                triggerWake()
            }
            if client.isConnected {
                Button("🌙 息屏休眠 (睡眠显示器)") {
                    client.displaySleep()
                }
                Button("💤 系统低功耗休眠") {
                    client.systemSleep()
                }
                Button("🔒 立即锁定屏幕") {
                    client.lockScreen()
                }
                Button("🔄 系统重启...", role: .destructive) {
                    showingRestartConfirm = true
                }
                Button("⚠️ 彻底关机...", role: .destructive) {
                    showingShutdownConfirm = true
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("确定要彻底关闭电脑吗？", isPresented: $showingShutdownConfirm, titleVisibility: .visible) {
            Button("彻底关机", role: .destructive) {
                client.shutdown()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("电脑关机后如断开电源将无法远程唤醒，请确认所有未保存工作已保存。")
        }
        .confirmationDialog("确定要重启电脑吗？", isPresented: $showingRestartConfirm, titleVisibility: .visible) {
            Button("重新启动", role: .destructive) {
                client.restart()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重启后需等待系统就绪后方可再次连上。")
        }
        .alert(isPresented: $showingPowerAlert) {
            Alert(title: Text(powerAlertTitle), message: Text(powerAlertMsg), dismissButton: .default(Text("好")))
        }
    }

    private func tabButton(title: String, icon: String, index: Int) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            appState.selectedTab = index
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 11, weight: appState.selectedTab == index ? .bold : .regular))
            }
            .foregroundColor(appState.selectedTab == index ? AppTheme.accent : AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Host Picker Sheet (When multiple Macs exist)

struct HostPickerSheet: View {
    @ObservedObject var client = MultipeerClient.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("局域网中发现的 Mac 电脑").font(.system(size: 12))) {
                    if client.discoveredHosts.isEmpty {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("正在搜索局域网中的 Mac...")
                                .font(.system(size: 13))
                                .foregroundColor(AppTheme.textSecondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(client.discoveredHosts, id: \.displayName) { peer in
                            Button {
                                client.connect(to: peer)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer")
                                        .font(.system(size: 16))
                                        .foregroundColor(AppTheme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.displayName)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AppTheme.textPrimary)
                                        Text("Apple 原生对等互联直连")
                                            .font(.system(size: 11))
                                            .foregroundColor(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                    if client.connectedHostName == peer.displayName {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(AppTheme.accent)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        client.start()
                    } label: {
                        HStack {
                            Spacer()
                            Text("重新扫描")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppTheme.accent)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("选择控制的电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}
