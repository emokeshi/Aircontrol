import SwiftUI
import UIKit

// MARK: - Live System Keyboard Proxy (Supports Backspace, Return, Modifiers & IME)

final class LiveKeyProxyView: UITextView, UITextViewDelegate {
    var onCharacter: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onReturn: (() -> Void)?

    private let sentinel = "\u{200B}"

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        self.delegate = self
        self.text = sentinel
        self.autocorrectionType = .no
        self.autocapitalizationType = .none
        self.spellCheckingType = .no
        self.smartQuotesType = .no
        self.smartDashesType = .no
        self.returnKeyType = .default
        self.backgroundColor = .clear
        self.textColor = .clear
        self.tintColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Allow Chinese/Japanese IME composition while markedTextRange is active
        if textView.markedTextRange != nil {
            return true
        }

        if text == "\n" {
            onReturn?()
            resetSentinel()
            return false
        }

        if text.isEmpty && range.length > 0 {
            onBackspace?()
            resetSentinel()
            return false
        }

        if !text.isEmpty {
            onCharacter?(text)
            resetSentinel()
            return false
        }

        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        // When IME composition finishes (e.g. selecting a Chinese word from candidate bar)
        guard textView.markedTextRange == nil else { return }
        let current = textView.text ?? ""
        let committed = current.replacingOccurrences(of: sentinel, with: "")
        if !committed.isEmpty {
            onCharacter?(committed)
            resetSentinel()
        } else if current.isEmpty {
            resetSentinel()
        }
    }

    private func resetSentinel() {
        self.text = sentinel
        let endPos = self.endOfDocument
        self.selectedTextRange = self.textRange(from: endPos, to: endPos)
    }
}

struct LiveKeyResponderRepresentable: UIViewRepresentable {
    let isFirstResponder: Bool
    let onCharacter: (String) -> Void
    let onBackspace: () -> Void
    let onReturn: () -> Void

    func makeUIView(context: Context) -> LiveKeyProxyView {
        let view = LiveKeyProxyView(frame: .zero, textContainer: nil)
        view.onCharacter = onCharacter
        view.onBackspace = onBackspace
        view.onReturn = onReturn
        return view
    }

    func updateUIView(_ uiView: LiveKeyProxyView, context: Context) {
        uiView.onCharacter = onCharacter
        uiView.onBackspace = onBackspace
        uiView.onReturn = onReturn

        if isFirstResponder && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        } else if !isFirstResponder && uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.resignFirstResponder()
            }
        }
    }
}

// MARK: - Compact Keyboard Accessory Strip (Used with Native iOS Keyboard)

public struct KeyboardDeckView: View {
    @State private var cmd: Bool = false
    @State private var opt: Bool = false
    @State private var ctrl: Bool = false

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private static let ansiKeyMap: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49
    ]

    public init() {}

    private func sendKey(keyCode: UInt16) {
        haptic.impactOccurred()
        MultipeerClient.shared.sendKeyEvent(keyCode: keyCode, action: "down", cmd: cmd, opt: opt, ctrl: ctrl, shift: false)
        MultipeerClient.shared.sendKeyEvent(keyCode: keyCode, action: "up", cmd: cmd, opt: opt, ctrl: ctrl, shift: false)
        cmd = false
        opt = false
        ctrl = false
    }

    private func handleTypedText(_ text: String) {
        if (cmd || opt || ctrl), text.count == 1, let ch = text.lowercased().first, let code = Self.ansiKeyMap[ch] {
            sendKey(keyCode: code)
            return
        }
        MultipeerClient.shared.sendTextCommit(text)
    }

    private func pastePhoneClipboard() {
        haptic.impactOccurred()
        if let str = UIPasteboard.general.string, !str.isEmpty {
            MultipeerClient.shared.sendTextCommit(str)
        } else {
            // Fallback: trigger Cmd+V on Mac
            MultipeerClient.shared.sendKeyEvent(keyCode: 9, action: "down", cmd: true, opt: false, ctrl: false, shift: false)
            MultipeerClient.shared.sendKeyEvent(keyCode: 9, action: "up", cmd: true, opt: false, ctrl: false, shift: false)
        }
    }

    private func keyPill(_ label: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? .white : AppTheme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(isActive ? AppTheme.accent : AppTheme.surface)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isActive ? AppTheme.accent : AppTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(AppTheme.border)

            // Hidden native UITextView that summons the system iOS keyboard
            LiveKeyResponderRepresentable(
                isFirstResponder: AppState.shared.activePanel == .keyboard,
                onCharacter: { text in handleTypedText(text) },
                onBackspace: { sendKey(keyCode: 51) },
                onReturn: { sendKey(keyCode: 36) }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    keyPill("Esc") { sendKey(keyCode: 53) }
                    keyPill("Tab") { sendKey(keyCode: 48) }
                    keyPill("⌘", isActive: cmd) {
                        haptic.impactOccurred()
                        cmd.toggle()
                    }
                    keyPill("⌥", isActive: opt) {
                        haptic.impactOccurred()
                        opt.toggle()
                    }
                    keyPill("⌃", isActive: ctrl) {
                        haptic.impactOccurred()
                        ctrl.toggle()
                    }
                    keyPill("粘贴") { pastePhoneClipboard() }
                    keyPill("←") { sendKey(keyCode: 123) }
                    keyPill("↓") { sendKey(keyCode: 125) }
                    keyPill("↑") { sendKey(keyCode: 126) }
                    keyPill("→") { sendKey(keyCode: 124) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(AppTheme.surfaceElevated)
        }
    }
}
