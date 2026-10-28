import SwiftUI
import UIKit

public struct DockView: View {
    @ObservedObject var client = MultipeerClient.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(AppTheme.border)

            HStack(spacing: 8) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    client.requestDock()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                        .padding(8)
                }
                .buttonStyle(.plain)

                if client.dockApps.isEmpty {
                    Spacer()
                    Button(client.isConnected ? "轻触同步 Mac 运行中程序" : "未连接 Mac") {
                        if client.isConnected {
                            client.requestDock()
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(client.dockApps) { app in
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    client.activateApp(bundleId: app.bundleId)
                                } label: {
                                    VStack(spacing: 3) {
                                        ZStack(alignment: .bottom) {
                                            if let iconStr = app.iconBase64,
                                               let data = Data(base64Encoded: iconStr),
                                               let uiImage = UIImage(data: data) {
                                                Image(uiImage: uiImage)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fit)
                                                    .frame(width: 38, height: 38)
                                                    .cornerRadius(9)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 9)
                                                            .stroke(app.isActive ? AppTheme.accent : AppTheme.border, lineWidth: app.isActive ? 1.5 : 1)
                                                    )
                                            } else {
                                                RoundedRectangle(cornerRadius: 9)
                                                    .fill(AppTheme.surfaceElevated)
                                                    .frame(width: 38, height: 38)
                                                    .overlay(
                                                        Image(systemName: "app.fill")
                                                            .font(.system(size: 16))
                                                            .foregroundColor(AppTheme.textTertiary)
                                                    )
                                            }

                                            if app.isActive {
                                                Circle()
                                                    .fill(AppTheme.accent)
                                                    .frame(width: 4, height: 4)
                                                    .offset(y: 4)
                                            }
                                        }

                                        Text(app.name)
                                            .font(.system(size: 10, weight: app.isActive ? .semibold : .regular))
                                            .foregroundColor(app.isActive ? AppTheme.accent : AppTheme.textSecondary)
                                            .lineLimit(1)
                                            .frame(width: 52)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(height: 64)
            .padding(.horizontal, 8)
            .background(AppTheme.surface)
        }
    }
}
