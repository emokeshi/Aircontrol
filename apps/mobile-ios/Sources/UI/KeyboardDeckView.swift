import SwiftUI
import UIKit

// MARK: - Native UIKit Input Field & Live IME/Dictation Proxy

final class LiveKeyProxyView: UITextView, UITextViewDelegate {
    var onCharacter: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onShortcutIntercept: ((String) -> Bool)?

    /// Tracks the committed text (excluding markedTextRange) already synced to the Mac.
    /// By diffing against `lastSyncedText` instead of overwriting `self.text`,
    /// Chinese Pinyin (`markedTextRange`) and iOS Voice Dictation (`UIDictationController`)
    /// never get interrupted or auto-paused.
    private var lastSyncedText: String = ""
    private var isInternalReset: Bool = false
    var isBecomingFirstResponder: Bool = false

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = "输入拼音、文字或使用键盘语音输入..."
        label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        label.textColor = UIColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1.0)
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var clearButton: UIButton = {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        btn.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        btn.tintColor = UIColor(red: 0.68, green: 0.68, blue: 0.70, alpha: 1.0)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isHidden = true
        btn.addTarget(self, action: #selector(handleClearTapped), for: .touchUpInside)
        return btn
    }()

    override var hasText: Bool {
        // Always report true so iOS keyboard Backspace key invokes deleteBackward() even when buffer is empty
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
        self.returnKeyType = .default
        self.enablesReturnKeyAutomatically = false
        self.showsVerticalScrollIndicator = false
        self.showsHorizontalScrollIndicator = false
        self.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 32)
        self.textContainer.lineFragmentPadding = 0

        addSubview(placeholderLabel)
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor, constant: 10),
            placeholderLabel.centerYAnchor.constraint(equalTo: frameLayoutGuide.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: frameLayoutGuide.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 26),
            clearButton.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        super.setMarkedText(markedText, selectedRange: selectedRange)
        updateAccessoryVisibility()
    }

    override func unmarkText() {
        super.unmarkText()
        updateAccessoryVisibility()
        if !isInternalReset && self.markedTextRange == nil {
            syncCommittedDiff(currentText: self.text ?? "")
        }
    }

    @objc private func handleClearTapped() {
        clearLocalBufferSilently()
    }

    func clearLocalBufferSilently() {
        guard markedTextRange == nil else { return }
        isInternalReset = true
        lastSyncedText = ""
        self.text = ""
        isInternalReset = false
        updateAccessoryVisibility()
    }

    private func updateAccessoryVisibility() {
        let currentEmpty = (self.text ?? "").isEmpty && (self.markedTextRange == nil)
        placeholderLabel.isHidden = !currentEmpty
        clearButton.isHidden = currentEmpty || (self.markedTextRange != nil)
    }

    override func deleteBackward() {
        // 1. While composing Pinyin (e.g. "ni hao"), only delete inside the Pinyin composition buffer
        if markedTextRange != nil {
            super.deleteBackward()
            updateAccessoryVisibility()
            return
        }

        // 2. When local buffer is already empty, forward Backspace directly to Mac
        if (self.text ?? "").isEmpty {
            onBackspace?()
            return
        }

        // 3. Otherwise delete from self.text; textViewDidChange will compute the diff and send Backspace to Mac
        super.deleteBackward()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Only intercept single ASCII key when a modifier toggle (⌘ / ⌥ / ⌃) is active and no IME composition is active
        if textView.markedTextRange == nil, let intercept = onShortcutIntercept, text.count == 1, intercept(text) {
            return false
        }

        // If user presses Backspace when buffer is empty, forward Backspace to Mac without mutating self.text
        if textView.markedTextRange == nil, text.isEmpty, range.length > 0, (textView.text ?? "").isEmpty {
            onBackspace?()
            return false
        }

        // CRITICAL: Always return true and NEVER overwrite textView.text here!
        // Returning false or setting self.text aborts Chinese Pinyin composition on the 1st keystroke
        // and immediately stops iOS Voice Dictation after the 1st character.
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        updateAccessoryVisibility()
        guard !isInternalReset else { return }

        // Wait while Chinese Pinyin / Handwriting IME pre-edit composition is still active (underlined text)
        if textView.markedTextRange != nil {
            return
        }

        syncCommittedDiff(currentText: textView.text ?? "")
    }

    private func syncCommittedDiff(currentText: String) {
        let oldChars = Array(lastSyncedText)
        let newChars = Array(currentText)

        var commonLen = 0
        let minLen = min(oldChars.count, newChars.count)
        while commonLen < minLen && oldChars[commonLen] == newChars[commonLen] {
            commonLen += 1
        }

        let deleteCount = oldChars.count - commonLen
        let addedSlice = newChars[commonLen..<newChars.count]

        lastSyncedText = currentText

        if deleteCount > 0 {
            for _ in 0..<deleteCount {
                onBackspace?()
            }
        }

        if !addedSlice.isEmpty {
            emitAddedText(String(addedSlice))
        }
    }

    private func emitAddedText(_ str: String) {
        let parts = str.components(separatedBy: "\n")
        for (index, part) in parts.enumerated() {
            if !part.isEmpty {
                onCharacter?(part)
            }
            if index < parts.count - 1 {
                onReturn?()
            }
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        // Flush any remaining committed text and reset local preview buffer for next session
        if textView.markedTextRange == nil {
            syncCommittedDiff(currentText: textView.text ?? "")
            clearLocalBufferSilently()
        }
        DispatchQueue.main.async {
            if AppState.shared.activePanel == .keyboard {
                AppState.shared.activePanel = nil
            }
        }
    }
}

struct LiveKeyResponderRepresentable: UIViewRepresentable {
    let isFirstResponder: Bool
    let onCharacter: (String) -> Void
    let onBackspace: () -> Void
    let onReturn: () -> Void
    let onShortcutIntercept: (String) -> Bool

    func makeUIView(context: Context) -> LiveKeyProxyView {
        let view = LiveKeyProxyView(frame: .zero, textContainer: nil)
        view.onCharacter = onCharacter
        view.onBackspace = onBackspace
        view.onReturn = onReturn
        view.onShortcutIntercept = onShortcutIntercept
        return view
    }

    func updateUIView(_ uiView: LiveKeyProxyView, context: Context) {
        uiView.onCharacter = onCharacter
        uiView.onBackspace = onBackspace
        uiView.onReturn = onReturn
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

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private static let ansiKeyMap: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49
    ]

    public init() {}

    /// Sends key event from live typing/dictation WITHOUT firing Taptic Engine (so iOS Voice Dictation is never disturbed)
    private func sendKeyFromInput(keyCode: UInt16) {
        MultipeerClient.shared.sendKeyEvent(keyCode: keyCode, action: "down", cmd: cmd, opt: opt, ctrl: ctrl, shift: false)
        MultipeerClient.shared.sendKeyEvent(keyCode: keyCode, action: "up", cmd: cmd, opt: opt, ctrl: ctrl, shift: false)
        if cmd || opt || ctrl {
            cmd = false
            opt = false
            ctrl = false
        }
    }

    /// Sends key event from toolbar button tap WITH light haptic feedback
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

    private func handleTypedText(_ text: String) {
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

            // Visible Single-Line Native Input Box:
            // Shows Pinyin pre-edit syllables ("ni hao") and live iOS Voice Dictation stream,
            // while syncing committed words to the Mac in real time.
            LiveKeyResponderRepresentable(
                isFirstResponder: AppState.shared.activePanel == .keyboard,
                onCharacter: { text in handleTypedText(text) },
                onBackspace: { sendKeyFromInput(keyCode: 51) },
                onReturn: { sendKeyFromInput(keyCode: 36) },
                onShortcutIntercept: { text in interceptShortcutIfNeeded(text) }
            )
            .frame(height: 36)
            .background(AppTheme.surface)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
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
