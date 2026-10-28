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
        for char in text {
            let utf16 = Array(String(char).utf16)
            var unichars = utf16

            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
                up.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
            }
        }
    }
}
