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
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { return }

        var flags = CGEventFlags()
        if modifiers.cmd { flags.insert(.maskCommand) }
        if modifiers.opt { flags.insert(.maskAlternate) }
        if modifiers.ctrl { flags.insert(.maskControl) }
        if modifiers.shift { flags.insert(.maskShift) }

        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }

    public func typeUnicodeString(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }

        // Chunk up to 16 UTF-16 code units per CGEvent so multi-character IME words and pasted text never drop characters
        let chunkSize = 16
        var offset = 0
        while offset < utf16.count {
            let end = min(offset + chunkSize, utf16.count)
            var slice = Array(utf16[offset..<end])

            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                down.flags = []
                up.flags = []
                down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
            }
            offset = end
            if offset < utf16.count {
                usleep(1200)
            }
        }
    }
}
