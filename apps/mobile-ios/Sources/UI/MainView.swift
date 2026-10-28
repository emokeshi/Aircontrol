import SwiftUI
import UIKit
import MultipeerConnectivity

public struct MainView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var client = MultipeerClient.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Minimalist Top Status Bar (36pt)
            HStack(spacing: 8) {
                Button {
                    appState.showHostPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Text(client.isConnected ? (client.connectedHostName.isEmpty ? "已连接" : client.connectedHostName) : (client.isSearching ? "搜索中..." : "未连接"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.textPrimary)
                            .lineLimit(1)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(AppTheme.textTertiary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Circle()
                    .fill(client.isConnected ? AppTheme.success : Color.gray.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(AppTheme.surface)

            // Primary Trackpad Canvas (Always stays active in the upper area)
            TrackpadView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Collapsible Bottom Half-Screen Drawer
            if let panel = appState.activePanel {
                switch panel {
                case .keyboard:
                    KeyboardDeckView()
                case .dock:
                    DockView()
                case .media:
                    MediaDeckView()
                case .settings:
                    SystemDeckView()
                }
            }

            Divider()
                .background(AppTheme.border)

            // Bottom Toolbar (4 Clean Icon Items)
            HStack(spacing: 0) {
                toolbarButton(icon: "keyboard", label: "键盘", panel: .keyboard)
                toolbarButton(icon: "macwindow", label: "程序", panel: .dock)
                toolbarButton(icon: "speaker.wave.2", label: "媒体", panel: .media)
                toolbarButton(icon: "slider.horizontal.3", label: "设置", panel: .settings)
            }
            .frame(height: 50)
            .background(AppTheme.surface)
        }
        .background(AppTheme.background)
        .preferredColorScheme(.light)
        .sheet(isPresented: $appState.showHostPicker) {
            HostPickerSheet()
        }
    }

    private func toolbarButton(icon: String, label: String, panel: DrawerPanel) -> some View {
        let isSelected = (appState.activePanel == panel)
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            appState.togglePanel(panel)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: isSelected ? .medium : .regular))
            }
            .foregroundColor(isSelected ? AppTheme.accent : AppTheme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Device Picker Sheet (Supports Manual IP Input & Auto Discovery)

struct HostPickerSheet: View {
    @ObservedObject var client = MultipeerClient.shared
    @State private var manualIP: String = ""
    @State private var manualMac: String = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("电脑")) {
                    if client.discoveredHosts.isEmpty && !client.isConnected {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("正在搜索...")
                                .font(.system(size: 13))
                                .foregroundColor(AppTheme.textSecondary)
                        }
                    } else {
                        if client.isConnected && !client.discoveredHosts.contains(where: { $0.displayName == client.connectedHostName }) {
                            HStack {
                                Text(client.connectedHostName.isEmpty ? client.hostIP : client.connectedHostName)
                                    .font(.system(size: 14))
                                    .foregroundColor(AppTheme.textPrimary)
                                Spacer()
                                Image(systemName: "checkmark")
                                    .foregroundColor(AppTheme.accent)
                            }
                        }

                        ForEach(client.discoveredHosts, id: \.displayName) { peer in
                            Button {
                                client.connect(to: peer)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(peer.displayName)
                                        .font(.system(size: 14))
                                        .foregroundColor(AppTheme.textPrimary)
                                    Spacer()
                                    if client.connectedHostName == peer.displayName {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(AppTheme.accent)
                                    }
                                }
                            }
                        }
                    }

                    Button("重新搜索") {
                        client.rescan()
                    }
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.accent)
                }

                Section(header: Text("唤醒设置 (MAC)")) {
                    HStack {
                        TextField("00:00:00:00:00:00", text: $manualMac)
                            .font(.system(size: 13, design: .monospaced))
                            .autocapitalization(.allCharacters)
                            .disableAutocorrection(true)

                        Button("保存") {
                            let trimmed = manualMac.trimmingCharacters(in: .whitespacesAndNewlines)
                            client.targetMacAddress = trimmed
                            UserDefaults.standard.set(trimmed, forKey: "aircontrol_saved_mac")
                        }
                        .font(.system(size: 13))
                    }
                }
            }
            .onAppear {
                manualIP = client.hostIP
                manualMac = client.targetMacAddress
            }
            .navigationTitle("连接")
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
