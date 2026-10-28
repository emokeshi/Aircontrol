import SwiftUI
import UIKit

public struct MediaDeckView: View {
    @ObservedObject var client = MultipeerClient.shared
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(AppTheme.border)

            VStack(spacing: 22) {
                // Playback Transport Controls
                HStack(spacing: 48) {
                    Button {
                        haptic.impactOccurred()
                        client.prevTrack()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 22))
                            .foregroundColor(AppTheme.textPrimary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)

                    Button {
                        haptic.impactOccurred()
                        client.playPause()
                    } label: {
                        Image(systemName: "playpause.fill")
                            .font(.system(size: 26))
                            .foregroundColor(AppTheme.textPrimary)
                            .frame(width: 52, height: 52)
                            .background(AppTheme.surfaceElevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        haptic.impactOccurred()
                        client.nextTrack()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 22))
                            .foregroundColor(AppTheme.textPrimary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }

                // Volume Slider
                HStack(spacing: 12) {
                    Button {
                        haptic.impactOccurred()
                        client.toggleMute()
                    } label: {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 15))
                            .foregroundColor(AppTheme.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)

                    Slider(
                        value: Binding(
                            get: { Double(client.hostVolume) },
                            set: { client.setVolume(Float($0)) }
                        ),
                        in: 0...1
                    )
                    .tint(AppTheme.accent)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 15))
                        .foregroundColor(AppTheme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(height: 165)
            .background(AppTheme.surface)
        }
    }
}
