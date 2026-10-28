import Foundation
import SwiftUI
import Combine

public enum DrawerPanel: Int, Equatable {
    case keyboard = 1
    case dock = 2
    case media = 3
    case settings = 4
}

public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var activePanel: DrawerPanel? = nil
    @Published public var showHostPicker: Bool = false

    private init() {
        MultipeerClient.shared.start()
    }

    public func togglePanel(_ panel: DrawerPanel) {
        withAnimation(.easeOut(duration: 0.18)) {
            if activePanel == panel {
                activePanel = nil
            } else {
                activePanel = panel
            }
        }
    }
}
