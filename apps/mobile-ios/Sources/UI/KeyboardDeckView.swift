import SwiftUI
import UIKit

// MARK: - Native UIKit Input Field (Compose Pinyin / Voice Dictation -> Tap Send -> Auto-Clear)

final class LiveKeyProxyView: UITextView, UITextViewDelegate {
    var onSendText: ((String) -> Void)?
    var onBackspaceWhenEmpty: (() -> Void)?
    var onReturnWhenEmpty: (() -> Void)?
    var onShortcutIntercept: ((String) -> Bool)?

    var isBecomingFirstResponder: Bool = false

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = "输入文字、拼音或语音，点发送上屏..."
        label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        label.textColor = UIColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1.0)
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override var hasText: Bool {
        // Always report true so iOS keyboard Backspace key & Send key remain enabled even when input box is empty
        return true
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        self.delegate = self
        self.text = ""
        self.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        self.textColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        self.tintColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        self.backgroundColor = .clear
        self.autocorrectionType = .default
        self.spellCheckingType = .default
        self.autocapitalizationType = .none
        self.smartQuotesType = .no
        self.smartDashesType = .no
        self.returnKeyType = .send
        self.enablesReturnKeyAutomatically = false
        self.showsVerticalScrollIndicator = false
        self.showsHorizontalScrollIndicator = false
        self.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        self.textContainer.lineFragmentPadding = 0

        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor, constant: 10),
            placeholderLabel.centerYAnchor.constraint(equalTo: frameLayoutGuide.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        super.setMarkedText(markedText, selectedRange: selectedRange)
        updatePlaceholderVisibility()
    }

    override func unmarkText() {
        super.unmarkText()
        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        let isEmpty = (self.text ?? "").isEmpty && (self.markedTextRange == nil)
        placeholderLabel.isHidden = !isEmpty
    }

    /// Sends all text currently in the input box to the Mac and immediately clears the input box!
    func submitAndClear() {
        if self.markedTextRange != nil {
            self.unmarkText()
        }
        let current = self.text ?? ""
        if !current.isEmpty {
            self.text = ""
            updatePlaceholderVisibility()
            onSendText?(current)
        } else {
            onReturnWhenEmpty?()
        }
    }

    override func deleteBackward() {
        // 1. If Pinyin composition is active, delete inside Pinyin buffer
        if markedTextRange != nil {
            super.deleteBackward()
            updatePlaceholderVisibility()
            return
        }

        // 2. If input box is empty, pressing Backspace on iOS keyboard deletes directly on the Mac!
        if (self.text ?? "").isEmpty {
            onBackspaceWhenEmpty?()
            return
        }

        // 3. Otherwise delete inside the local input box
        super.deleteBackward()
        updatePlaceholderVisibility()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // 1. Allow all Pinyin / Handwriting IME pre-edit operations when markedTextRange is active
        if textView.markedTextRange != nil {
            return true
        }

        // 2. If a shortcut modifier (⌘ / ⌥ / ⌃) is toggled on, fire the shortcut immediately
        if let intercept = onShortcutIntercept, text.count == 1, intercept(text) {
            return false
        }

        // 3. When user taps the iOS keyboard's "发送" (Return) key:
        //    Send the text in the input box to Mac and immediately clear the input box!
        if text == "\n" {
            submitAndClear()
            return false
        }

        // 4. When input box is already empty and user taps Backspace, delete on Mac
        if text.isEmpty && range.length > 0 && (textView.text ?? "").isEmpty {
            onBackspaceWhenEmpty?()
            return false
        }

        // 5. All other typing & iOS Voice Dictation: return true without mutating self.text
        //    so Pinyin and continuous Voice Dictation never get interrupted!
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholderVisibility()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        DispatchQueue.main.async {
            if AppState.shared.activePanel == .keyboard {
                AppState.shared.activePanel = nil
            }
        }
    }
}

final class KeyboardInputController {
    weak var textView: LiveKeyProxyView?

    func triggerSubmit() {
        textView?.submitAndClear()
    }
}

struct LiveKeyResponderRepresentable: UIViewRepresentable {
    let isFirstResponder: Bool
    let controller: KeyboardInputController
    let onSendText: (String) -> Void
    let onBackspaceWhenEmpty: () -> Void
    let onReturnWhenEmpty: () -> Void
    let onShortcutIntercept: (String) -> Bool

    func makeUIView(context: Context) -> LiveKeyProxyView {
        let view = LiveKeyProxyView(frame: .zero, textContainer: nil)
        controller.textView = view
        view.onSendText = onSendText
        view.onBackspaceWhenEmpty = onBackspaceWhenEmpty
        view.onReturnWhenEmpty = onReturnWhenEmpty
        view.onShortcutIntercept = onShortcutIntercept
        return view
    }

    func updateUIView(_ uiView: LiveKeyProxyView, context: Context) {
        controller.textView = uiView
        uiView.onSendText = onSendText
        uiView.onBackspaceWhenEmpty = onBackspaceWhenEmpty
        uiView.onReturnWhenEmpty = onReturnWhenEmpty
        uiView.onShortcutIntercept = onShortcutIntercept

        if isFirstResponder && !uiView.isFirstResponder && !uiView.isBecomingFirstResponder {
            uiView.isBecomingFirstResponder = true
            DispatchQueue.main.async {
                _ = uiView.becomeFirstResponder()
                uiView.isBecomingFirstResponder = false
            }
        } else if !isFirstResponder && uiView.isFirstResponder {
            DispatchQueue.main.async {
                _ = uiView.resignFirstResponder()
            }
        }
    }
}

// MARK: - Compact Keyboard Input & Shortcut Strip (Used with Native iOS Keyboard)

public struct KeyboardDeckView: View {
    @State private var cmd: Bool = false
    @State private var opt: Bool = false
    @State private var ctrl: Bool = false
    @State private var inputController = KeyboardInputController()

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private static let ansiKeyMap: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49
    ]

    public init() {}

    private func sendKeyFromInput(keyCode: UInt16) {
        MultipeerClient.shared.sendKeyEvent(keyCode: keyCode, action: "down", cmd: cmd, opt: opt, ctrl: ctrl, shift: false)
        MultipeerClient.shared.sendKeyEvent(keyCode: keyCode, action: "up", cmd: cmd, opt: opt, ctrl: ctrl, shift: false)
        if cmd || opt || ctrl {
            cmd = false
            opt = false
            ctrl = false
        }
    }

    private func sendKeyButton(keyCode: UInt16) {
        haptic.impactOccurred()
        sendKeyFromInput(keyCode: keyCode)
    }

    private func interceptShortcutIfNeeded(_ text: String) -> Bool {
        guard cmd || opt || ctrl else { return false }
        if text.count == 1, let ch = text.lowercased().first, let code = Self.ansiKeyMap[ch] {
            sendKeyFromInput(keyCode: code)
            return true
        }
        return false
    }

    private func handleSendText(_ text: String) {
        if interceptShortcutIfNeeded(text) {
            return
        }
        MultipeerClient.shared.sendTextCommit(text)
    }

    private func pastePhoneClipboard() {
        haptic.impactOccurred()
        if let str = UIPasteboard.general.string, !str.isEmpty {
            MultipeerClient.shared.sendTextCommit(str)
        } else {
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

            // Input Box + Send Button Row:
            // Type Pinyin or dictate with iOS Voice Input, then tap "发送" (or keyboard Send key)
            // to send to Mac and automatically clear the input box!
            HStack(spacing: 8) {
                LiveKeyResponderRepresentable(
                    isFirstResponder: AppState.shared.activePanel == .keyboard,
                    controller: inputController,
                    onSendText: { text in handleSendText(text) },
                    onBackspaceWhenEmpty: { sendKeyFromInput(keyCode: 51) },
                    onReturnWhenEmpty: { sendKeyFromInput(keyCode: 36) },
                    onShortcutIntercept: { text in interceptShortcutIfNeeded(text) }
                )
                .frame(height: 36)
                .background(AppTheme.surface)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.border, lineWidth: 1)
                )

                Button {
                    haptic.impactOccurred()
                    inputController.triggerSubmit()
                } label: {
                    Text("发送")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(AppTheme.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    keyPill("Esc") { sendKeyButton(keyCode: 53) }
                    keyPill("Tab") { sendKeyButton(keyCode: 48) }
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
                    keyPill("⌫") { sendKeyButton(keyCode: 51) }
                    keyPill("回车") { sendKeyButton(keyCode: 36) }
                    keyPill("←") { sendKeyButton(keyCode: 123) }
                    keyPill("↓") { sendKeyButton(keyCode: 125) }
                    keyPill("↑") { sendKeyButton(keyCode: 126) }
                    keyPill("→") { sendKeyButton(keyCode: 124) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .background(AppTheme.surfaceElevated)
    }
}
