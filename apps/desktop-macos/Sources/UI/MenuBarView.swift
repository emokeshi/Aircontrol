import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var state = AppState.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AirControl")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.12))

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(state.connectedClient != nil ? Color.green : Color.gray.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(state.connectedClient ?? "未连接")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.4))
                        .lineLimit(1)
                }
            }

            VStack(spacing: 8) {
                Toggle(isOn: $state.isNaturalScroll) {
                    Text("自然滚动")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.25))
                }
                .toggleStyle(.switch)

                Toggle(isOn: $state.launchAtLogin) {
                    Text("登录时打开")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.25))
                }
                .toggleStyle(.switch)

                Divider()

                HStack {
                    Text("IP 地址")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.5))
                    Spacer()
                    Text(state.localIP)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.25))
                }

                HStack {
                    Text("物理地址")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.5))
                    Spacer()
                    Text(state.macAddress)
                        .font(.system(size: 11, design: .monospaced))
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

            if !state.isAccessibilityGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("需要辅助功能权限")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(red: 0.7, green: 0.3, blue: 0.0))

                    Text("请在系统设置中允许 AirControl 控制电脑。")
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

            HStack {
                Spacer()
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.5))
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(Color.white)
        .preferredColorScheme(.light)
    }
}
