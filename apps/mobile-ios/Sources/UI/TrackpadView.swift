import SwiftUI
import UIKit

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

// MARK: - Hardware-Coalesced UIKit Touch View

final class TrackpadUIView: UIView {
    private var initialTouchPoint: CGPoint = .zero
    private var touchDownTime: TimeInterval = 0
    private var lastTapTime: TimeInterval = 0
    private var hasMovedSignificantly: Bool = false
    private var isTapDragging: Bool = false
    private var isFirstMoveInStroke: Bool = true

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
        let now = ProcessInfo.processInfo.systemUptime
        if event?.allTouches?.count == touches.count {
            initialTouchPoint = touch.location(in: self)
            touchDownTime = now
            hasMovedSignificantly = false
            isFirstMoveInStroke = true

            // Double-tap and hold to drag (native macOS trackpad gesture)
            if touches.count == 1 && (now - lastTapTime) < 0.25 {
                isTapDragging = true
                lightHaptic.impactOccurred()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let allTouches = event?.allTouches, !touches.isEmpty else { return }

        let fingerCount = allTouches.count
        var sumDx: Float = 0.0
        var sumDy: Float = 0.0
        var count: Float = 0.0

        for touch in touches {
            if let coalesced = event?.coalescedTouches(for: touch), !coalesced.isEmpty {
                var lastPt = touch.previousLocation(in: self)
                for cTouch in coalesced {
                    let pt = cTouch.location(in: self)
                    sumDx += Float(pt.x - lastPt.x)
                    sumDy += Float(pt.y - lastPt.y)
                    lastPt = pt
                }
            } else {
                let curr = touch.location(in: self)
                let prev = touch.previousLocation(in: self)
                sumDx += Float(curr.x - prev.x)
                sumDy += Float(curr.y - prev.y)
            }
            count += 1.0

            let curr = touch.location(in: self)
            if hypot(curr.x - initialTouchPoint.x, curr.y - initialTouchPoint.y) > 6.0 {
                hasMovedSignificantly = true
            }
        }

        guard count > 0 else { return }
        let avgDx = sumDx / count
        let avgDy = sumDy / count
        guard avgDx != 0 || avgDy != 0 else { return }

        let sens = Float(TrackpadSettings.shared.sensitivity)
        let dx = avgDx * sens
        let dy = avgDy * sens
        let strokeStart = isFirstMoveInStroke
        isFirstMoveInStroke = false

        if fingerCount == 1 {
            if isTapDragging {
                MultipeerClient.shared.sendDrag(dx: dx, dy: dy, isStrokeStart: strokeStart)
            } else {
                MultipeerClient.shared.sendMove(dx: dx, dy: dy, isStrokeStart: strokeStart)
            }
        } else if fingerCount >= 2 {
            MultipeerClient.shared.sendScroll(dx: dx, dy: dy, isStrokeStart: strokeStart)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let allTouches = event?.allTouches else { return }
        let remainingTouches = allTouches.subtracting(touches)

        if remainingTouches.isEmpty {
            if isTapDragging {
                isTapDragging = false
                MultipeerClient.shared.sendDragRelease()
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            let duration = now - touchDownTime

            if duration < 0.25 && !hasMovedSignificantly {
                let initialCount = allTouches.count
                if initialCount == 1 {
                    lastTapTime = now
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
        if isTapDragging {
            isTapDragging = false
            MultipeerClient.shared.sendDragRelease()
        }
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

// MARK: - Expansive Minimalist Trackpad View

public struct TrackpadView: View {
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            // Pure White Trackpad Surface
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppTheme.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )

                TrackpadRepresentable()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Left / Right Buttons
            HStack(spacing: 0) {
                Button {
                    lightHaptic.impactOccurred()
                    MultipeerClient.shared.sendClick(isRight: false)
                } label: {
                    Text("左键")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(AppTheme.border)
                    .frame(width: 1, height: 22)

                Button {
                    mediumHaptic.impactOccurred()
                    MultipeerClient.shared.sendClick(isRight: true)
                } label: {
                    Text("右键")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 44)
            .background(AppTheme.surface)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}
