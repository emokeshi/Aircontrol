import SwiftUI
import UIKit

// MARK: - Trackpad Client Settings (Golden Baseline 1.0x)

public final class TrackpadSettings: ObservableObject {
    public static let shared = TrackpadSettings()

    @Published public var sensitivity: Double {
        didSet {
            UserDefaults.standard.set(sensitivity, forKey: "aircontrol_client_sensitivity")
        }
    }

    private init() {
        let saved = UserDefaults.standard.double(forKey: "aircontrol_client_sensitivity")
        self.sensitivity = saved > 0.1 ? saved : 1.0
    }
}

// MARK: - Ultra-Low Latency UIKit Touch Interceptor

final class TrackpadUIView: UIView {
    private var initialTouchPoint: CGPoint = .zero
    private var touchDownTime: TimeInterval = 0
    private var hasMovedSignificantly: Bool = false
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        lightHaptic.prepare()
        mediumHaptic.prepare()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if event?.allTouches?.count == touches.count {
            initialTouchPoint = touch.location(in: self)
            touchDownTime = ProcessInfo.processInfo.systemUptime
            hasMovedSignificantly = false
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let allTouches = event?.allTouches, !touches.isEmpty else { return }

        let fingerCount = allTouches.count
        var sumDx: Float = 0.0
        var sumDy: Float = 0.0
        var count: Float = 0.0

        for touch in touches {
            let curr = touch.location(in: self)
            let prev = touch.previousLocation(in: self)
            sumDx += Float(curr.x - prev.x)
            sumDy += Float(curr.y - prev.y)
            count += 1.0

            let dist = hypot(curr.x - initialTouchPoint.x, curr.y - initialTouchPoint.y)
            if dist > 8.0 {
                hasMovedSignificantly = true
            }
        }

        guard count > 0 else { return }
        let avgDx = sumDx / count
        let avgDy = sumDy / count

        let sens = Float(TrackpadSettings.shared.sensitivity)
        let sendDx = avgDx * sens
        let sendDy = avgDy * sens

        // Direct zero-hop transmission: MCSession.send with .unreliable is non-blocking
        if fingerCount == 1 {
            MultipeerClient.shared.sendMove(dx: sendDx, dy: sendDy)
        } else if fingerCount >= 2 {
            MultipeerClient.shared.sendScroll(dx: sendDx, dy: sendDy)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let allTouches = event?.allTouches else { return }
        let remainingTouches = allTouches.subtracting(touches)

        // Only evaluate discrete tap when all fingers have lifted
        if remainingTouches.isEmpty {
            let duration = ProcessInfo.processInfo.systemUptime - touchDownTime

            // Discrete tap gesture (< 250ms and no significant motion)
            if duration < 0.25 && !hasMovedSignificantly {
                let initialCount = allTouches.count
                if initialCount == 1 {
                    lightHaptic.impactOccurred()
                    MultipeerClient.shared.sendClick(isRight: false)
                } else if initialCount >= 2 {
                    mediumHaptic.impactOccurred()
                    MultipeerClient.shared.sendClick(isRight: true)
                }
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        MultipeerClient.shared.sendDragRelease()
    }
}

struct TrackpadRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {}
}

// MARK: - Trackpad Container View

public struct TrackpadView: View {
    @ObservedObject var settings = TrackpadSettings.shared
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    public init() {}

    private func speedButton(label: String, val: Double) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            settings.sensitivity = val
        } label: {
            Text(label)
                .font(.system(size: 11, weight: abs(settings.sensitivity - val) < 0.05 ? .semibold : .regular))
                .foregroundColor(abs(settings.sensitivity - val) < 0.05 ? AppTheme.accent : AppTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(abs(settings.sensitivity - val) < 0.05 ? AppTheme.accentLight : AppTheme.surfaceElevated)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(abs(settings.sensitivity - val) < 0.05 ? AppTheme.accent.opacity(0.4) : AppTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Speed Bar
            HStack {
                Text("光标速度")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.textSecondary)

                HStack(spacing: 6) {
                    speedButton(label: "0.8x", val: 0.8)
                    speedButton(label: "1.0x", val: 1.0)
                    speedButton(label: "1.3x", val: 1.3)
                    speedButton(label: "1.6x", val: 1.6)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(AppTheme.success)
                        .frame(width: 6, height: 6)
                    Text("触控已连接")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            // Main Touch Surface (Apple Minimalist White Canvas)
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(AppTheme.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.02), radius: 8, x: 0, y: 3)

                // Subtle Centered Target Indicator
                Circle()
                    .stroke(AppTheme.borderSubtle.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 24, height: 24)

                TrackpadRepresentable()
            }
            .padding(.horizontal, 16)

            // Physical Button Bar (左键、双击、右键)
            HStack(spacing: 1) {
                Button {
                    lightHaptic.impactOccurred()
                    MultipeerClient.shared.sendClick(isRight: false)
                } label: {
                    Text("左键")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(AppTheme.border)
                    .frame(width: 1, height: 26)

                Button {
                    lightHaptic.impactOccurred()
                    MultipeerClient.shared.sendClick(isRight: false, isDouble: true)
                } label: {
                    Text("双击")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(AppTheme.border)
                    .frame(width: 1, height: 26)

                Button {
                    mediumHaptic.impactOccurred()
                    MultipeerClient.shared.sendClick(isRight: true)
                } label: {
                    Text("右键")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 48)
            .background(AppTheme.surface)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }
}
