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

                // Natural Scroll & Wake MAC
                HStack {
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
