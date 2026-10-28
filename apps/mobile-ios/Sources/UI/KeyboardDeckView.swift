import SwiftUI
import UIKit

public struct KeyboardDeckView: View {
    @State private var inputText: String = ""
    @State private var cmd: Bool = false
    @State private var opt: Bool = false
    @State private var ctrl: Bool = false
    @State private var shift: Bool = false

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    public init() {}

    private func sendShortcut(keyCode: UInt16, forceCmd: Bool = false, forceOpt: Bool = false, forceCtrl: Bool = false, forceShift: Bool = false) {
        haptic.impactOccurred()
        let finalCmd = cmd || forceCmd
        let finalOpt = opt || forceOpt
        let finalCtrl = ctrl || forceCtrl
        let finalShift = shift || forceShift

        MultipeerClient.shared.sendKeyEvent(keyCode: keyCode, action: "down", cmd: finalCmd, opt: finalOpt, ctrl: finalCtrl, shift: finalShift)
        MultipeerClient.shared.sendKeyEvent(keyCode: keyCode, action: "up", cmd: finalCmd, opt: finalOpt, ctrl: finalCtrl, shift: finalShift)
    }

    private func commitText() {
        guard !inputText.isEmpty else { return }
        haptic.impactOccurred()
        MultipeerClient.shared.sendTextCommit(inputText)
        inputText = ""
    }

    private func modifierButton(label: String, isActive: Binding<Bool>) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            isActive.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isActive.wrappedValue ? .white : AppTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isActive.wrappedValue ? AppTheme.accent : AppTheme.surfaceElevated)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isActive.wrappedValue ? AppTheme.accent : AppTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func actionButton(label: String, keyCode: UInt16, forceCmd: Bool = false, forceShift: Bool = false) -> some View {
        Button {
            sendShortcut(keyCode: keyCode, forceCmd: forceCmd, forceShift: forceShift)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(AppTheme.surface)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Unicode Text Typing Field (Direct IME Stream to Mac)
                HStack(spacing: 8) {
                    TextField("在此输入中文/文本，直接发送至 Mac...", text: $inputText)
                        .font(.system(size: 14))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(AppTheme.surfaceElevated)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AppTheme.border, lineWidth: 1)
                        )
                        .onSubmit {
                            commitText()
                        }

                    Button {
                        commitText()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }

                // Modifiers Row
                HStack(spacing: 8) {
                    modifierButton(label: "⌘ Command", isActive: $cmd)
                    modifierButton(label: "⌥ Option", isActive: $opt)
                    modifierButton(label: "⌃ Control", isActive: $ctrl)
                    modifierButton(label: "⇧ Shift", isActive: $shift)
                }

                // Quick Action Macros
                VStack(alignment: .leading, spacing: 8) {
                    Text("常用快捷键")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)

                    HStack(spacing: 8) {
                        actionButton(label: "聚焦 (⌘ 空格)", keyCode: 49, forceCmd: true)
                        actionButton(label: "拷贝 (⌘ C)", keyCode: 8, forceCmd: true)
                        actionButton(label: "粘贴 (⌘ V)", keyCode: 9, forceCmd: true)
                    }

                    HStack(spacing: 8) {
                        actionButton(label: "全选 (⌘ A)", keyCode: 0, forceCmd: true)
                        actionButton(label: "撤销 (⌘ Z)", keyCode: 6, forceCmd: true)
                        actionButton(label: "截屏 (⌘⇧4)", keyCode: 21, forceCmd: true, forceShift: true)
                    }

                    HStack(spacing: 8) {
                        actionButton(label: "退出 (Esc)", keyCode: 53)
                        actionButton(label: "回车 (Return)", keyCode: 36)
                        actionButton(label: "删除 (Delete)", keyCode: 51)
                    }
                }
            }
            .padding(16)
        }
    }
}
