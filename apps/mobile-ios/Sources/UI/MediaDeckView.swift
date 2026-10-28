import SwiftUI
import UIKit

public struct MediaDeckView: View {
    @State private var volume: Float = 0.5
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    public init() {}

    private func volumePill(percent: Int) -> some View {
        Button {
            haptic.impactOccurred()
            volume = Float(percent) / 100.0
            MultipeerClient.shared.setVolume(volume)
        } label: {
            Text("\(percent)%")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(AppTheme.surfaceElevated)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Volume Card
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 14))
                        .foregroundColor(AppTheme.accent)
                    Text("Mac 原生系统音量")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Spacer()
                    Text("\(Int(volume * 100))%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(AppTheme.accent)
                }

                HStack(spacing: 12) {
                    Button {
                        haptic.impactOccurred()
                        MultipeerClient.shared.toggleMute()
                    } label: {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 16))
                            .foregroundColor(AppTheme.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)

                    Slider(value: $volume, in: 0...1) { _ in
                        MultipeerClient.shared.setVolume(volume)
                    }
                    .tint(AppTheme.accent)

                    Button {
                        haptic.impactOccurred()
                        volume = min(1.0, volume + 0.1)
                        MultipeerClient.shared.setVolume(volume)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 16))
                            .foregroundColor(AppTheme.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    volumePill(percent: 0)
                    volumePill(percent: 25)
                    volumePill(percent: 50)
                    volumePill(percent: 75)
                    volumePill(percent: 100)
                }
            }
            .padding(16)
            .background(AppTheme.surface)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppTheme.border, lineWidth: 1)
            )

            // Playback Transport Controls
            VStack(spacing: 16) {
                Text("媒体播放控制")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.textSecondary)

                HStack(spacing: 40) {
                    Button {
                        haptic.impactOccurred()
                        MultipeerClient.shared.prevTrack()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 24))
                            .foregroundColor(AppTheme.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        haptic.impactOccurred()
                        MultipeerClient.shared.playPause()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(AppTheme.accent)
                                .frame(width: 60, height: 60)
                            Image(systemName: "play.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        haptic.impactOccurred()
                        MultipeerClient.shared.nextTrack()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 24))
                            .foregroundColor(AppTheme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 16)

            Spacer()
        }
        .padding(16)
    }
}
