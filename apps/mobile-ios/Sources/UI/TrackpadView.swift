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
    private var touchDownTime: TimeInterval = 0
    private var totalPathDistance: CGFloat = 0
    private var maxTouchCountInStroke: Int = 0
    private var isThreeFingerDragging: Bool = false
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
        let allCount = event?.allTouches?.count ?? touches.count
        if allCount == touches.count {
            // Fresh stroke started
            touchDownTime = ProcessInfo.processInfo.systemUptime
            totalPathDistance = 0
            maxTouchCountInStroke = allCount
            isFirstMoveInStroke = true
        } else {
            maxTouchCountInStroke = max(maxTouchCountInStroke, allCount)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let allTouches = event?.allTouches, !touches.isEmpty else { return }

        let activeTouches = allTouches.filter { $0.phase != .ended && $0.phase != .cancelled }
        let fingerCount = max(1, activeTouches.count)
        maxTouchCountInStroke = max(maxTouchCountInStroke, fingerCount)

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
        }

        guard count > 0 else { return }
        let avgDx = sumDx / count
        let avgDy = sumDy / count
        guard avgDx != 0 || avgDy != 0 else { return }

        totalPathDistance += CGFloat(hypot(avgDx, avgDy))

        let sens = Float(TrackpadSettings.shared.sensitivity)
        let dx = avgDx * sens
        let dy = avgDy * sens
        let strokeStart = isFirstMoveInStroke
        isFirstMoveInStroke = false

        if fingerCount == 1 {
            // Single finger ONLY moves cursor (never auto-drags unless user is explicitly holding the bottom Left Button)
            if isThreeFingerDragging {
                isThreeFingerDragging = false
                MultipeerClient.shared.sendDragRelease()
            }
            MultipeerClient.shared.sendMove(dx: dx, dy: dy, isStrokeStart: strokeStart)
        } else if fingerCount == 2 {
            if isThreeFingerDragging {
                isThreeFingerDragging = false
                MultipeerClient.shared.sendDragRelease()
            }
            MultipeerClient.shared.sendScroll(dx: dx, dy: dy, isStrokeStart: strokeStart)
        } else if fingerCount >= 3 {
            // Native macOS Three-Finger Drag (三指拖移)
            if !isThreeFingerDragging {
                isThreeFingerDragging = true
                lightHaptic.impactOccurred()
            }
            MultipeerClient.shared.sendDrag(dx: dx, dy: dy, isStrokeStart: strokeStart)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let allTouches = event?.allTouches else { return }
        let remainingTouches = allTouches.subtracting(touches).filter { $0.phase != .ended && $0.phase != .cancelled }

        if remainingTouches.isEmpty {
            if isThreeFingerDragging {
                isThreeFingerDragging = false
                MultipeerClient.shared.sendDragRelease()
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            let duration = now - touchDownTime

            // Strict tap detection: only fire click if finger barely moved (< 1.8pt total path) and was brief (< 0.18s)
            if duration < 0.18 && totalPathDistance < 1.8 {
                if maxTouchCountInStroke == 1 {
                    lightHaptic.impactOccurred()
                    MultipeerClient.shared.sendClick(isRight: false)
                } else if maxTouchCountInStroke == 2 {
                    mediumHaptic.impactOccurred()
                    MultipeerClient.shared.sendClick(isRight: true)
                }
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isThreeFingerDragging {
            isThreeFingerDragging = false
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
    @State private var isHoldingLeftButton: Bool = false
    @State private var leftDownTime: TimeInterval = 0

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

            // Left / Right Physical Buttons (Left button supports both tap-click and press-hold-to-drag!)
            HStack(spacing: 0) {
                Text("左键")
                    .font(.system(size: 13, weight: isHoldingLeftButton ? .medium : .regular))
                    .foregroundColor(isHoldingLeftButton ? AppTheme.accent : AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(isHoldingLeftButton ? AppTheme.surfaceElevated : Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !isHoldingLeftButton {
                                    isHoldingLeftButton = true
                                    leftDownTime = ProcessInfo.processInfo.systemUptime
                                    lightHaptic.impactOccurred()
                                    MultipeerClient.shared.sendDragStart()
                                }
                            }
                            .onEnded { _ in
                                if isHoldingLeftButton {
                                    isHoldingLeftButton = false
                                    let heldDuration = ProcessInfo.processInfo.systemUptime - leftDownTime
                                    if heldDuration < 0.20 {
                                        MultipeerClient.shared.sendClick(isRight: false)
                                    } else {
                                        MultipeerClient.shared.sendDragRelease()
                                    }
                                }
                            }
                    )

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
