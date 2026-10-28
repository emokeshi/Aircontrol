import SwiftUI
import UIKit

public struct DockView: View {
    @ObservedObject var client = MultipeerClient.shared

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(AppTheme.border)

            if client.dockApps.isEmpty {
                VStack {
                    Spacer()
                    Text(client.isConnected ? "暂无运行中的应用" : "未连接")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                }
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .background(AppTheme.surface)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(client.dockApps) { app in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                client.activateApp(bundleId: app.bundleId)
                            } label: {
                                VStack(spacing: 5) {
                                    ZStack(alignment: .bottom) {
                                        if let iconStr = app.iconBase64,
                                           let data = Data(base64Encoded: iconStr),
                                           let uiImage = UIImage(data: data) {
                                            Image(uiImage: uiImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 44, height: 44)
                                                .cornerRadius(10)
                                        } else {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(AppTheme.surfaceElevated)
                                                .frame(width: 44, height: 44)
                                                .overlay(
                                                    Image(systemName: "app")
                                                        .font(.system(size: 18))
                                                        .foregroundColor(AppTheme.textTertiary)
                                                )
                                        }

                                        if app.isActive {
                                            Circle()
                                                .fill(AppTheme.accent)
                                                .frame(width: 5, height: 5)
                                                .offset(y: 5)
                                        }
                                    }

                                    Text(app.name)
                                        .font(.system(size: 11, weight: app.isActive ? .medium : .regular))
                                        .foregroundColor(app.isActive ? AppTheme.textPrimary : AppTheme.textSecondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("切换到前端") {
                                    client.activateApp(bundleId: app.bundleId)
                                }
                                Button("退出", role: .destructive) {
                                    client.terminateApp(bundleId: app.bundleId)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .frame(height: 195)
                .background(AppTheme.surface)
            }
        }
    }
}
