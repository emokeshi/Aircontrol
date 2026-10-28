import Foundation
import CoreGraphics

public final class KeyboardSimulator {
    public static let shared = KeyboardSimulator()

    private init() {}

    public struct Modifiers: Codable {
        public let cmd: Bool
        public let opt: Bool
        public let ctrl: Bool
        public let shift: Bool

        public init(cmd: Bool = false, opt: Bool = false, ctrl: Bool = false, shift: Bool = false) {
            self.cmd = cmd
            self.opt = opt
            self.ctrl = ctrl
            self.shift = shift
        }
    }

    public func postKeyEvent(keyCode: UInt16, isDown: Bool, modifiers: Modifiers) {
        let source = CGEventSource(stateID: .privateState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { return }

        var flags = CGEventFlags.maskNonCoalesced
        if modifiers.cmd { flags.insert(.maskCommand) }
        if modifiers.opt { flags.insert(.maskAlternate) }
        if modifiers.ctrl { flags.insert(.maskControl) }
        if modifiers.shift { flags.insert(.maskShift) }

        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }

    public func typeUnicodeString(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .privateState)

        // Post one Character (grapheme cluster / BMP char / surrogate pair) per CGEvent pair
        // with .privateState and .maskNonCoalesced so Chinese IME words, punctuation, and Emoji
        // never get swallowed by macOS TSM or coalesced across rapid dictation bursts.
        let characters = Array(text)
        for (index, ch) in characters.enumerated() {
            if ch == "\n" || ch == "\r" {
                postKeyEvent(keyCode: 36, isDown: true, modifiers: Modifiers())
                postKeyEvent(keyCode: 36, isDown: false, modifiers: Modifiers())
                if index + 1 < characters.count {
                    usleep(1200)
                }
                continue
            }

            var utf16 = Array(String(ch).utf16)
            guard !utf16.isEmpty else { continue }

            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.flags = .maskNonCoalesced
                up.flags = .maskNonCoalesced
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
            }

            if index + 1 < characters.count {
                usleep(1200)
            }
        }
    }
}
