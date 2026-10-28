import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var updater = Updater.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Clean Apple Native Minimalist Style
            HStack {
                Text("AirControl")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.12))

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(state.connectedClient != nil ? Color.green : Color.gray.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(state.connectedClient != nil ? state.connectedClient! : "等待连接")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 0.25, green: 0.25, blue: 0.3))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(red: 0.95, green: 0.96, blue: 0.97))
                .cornerRadius(10)
            }

            // Compact Settings Section
            VStack(spacing: 8) {
                Toggle(isOn: $state.isNaturalScroll) {
                    Text("触控板自然滚动")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.25))
                }
                .toggleStyle(.switch)

                Divider()

                HStack {
                    Text("连接模式")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.5))
                    Spacer()
                    Text("Apple 原生对等直连")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.25))
                }

                HStack {
                    Text("本机 IP")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.5))
                    Spacer()
                    Text(state.localIP)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.25))
                }

                HStack {
                    Text("网卡 MAC")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.5))
                    Spacer()
                    Text(state.macAddress)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.25))
                }
            }
            .padding(12)
            .background(Color(red: 0.98, green: 0.98, blue: 0.99))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(red: 0.92, green: 0.93, blue: 0.94), lineWidth: 1)
            )

            // Accessibility Warning Card (Only shown if ungranted)
            if !state.isAccessibilityGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("未授权辅助功能权限")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.7, green: 0.3, blue: 0.0))

                    Text("需在系统设置中允许 AirControl 控制光标。")
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0.5, green: 0.4, blue: 0.2))

                    Button("打开系统设置") {
                        AccessibilityManager.openAccessibilitySettings()
                        AccessibilityManager.requestAccess()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
                .padding(10)
                .background(Color(red: 1.0, green: 0.98, blue: 0.94))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
            }

            // Footer
            HStack {
                Button {
                    updater.checkForUpdates(showPromptIfLatest: true)
                } label: {
                    Text(updater.isChecking ? "检查中..." : "检查更新 (v1.2.0)")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.5))
                }
                .buttonStyle(.plain)

                Spacer()

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.red)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(Color.white)
        .preferredColorScheme(.light)
    }
}
