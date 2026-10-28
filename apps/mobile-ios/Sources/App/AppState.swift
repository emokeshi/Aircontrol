import Foundation
import SwiftUI
import Combine

public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var selectedTab: Int = 0
    @Published public var showHostPicker: Bool = false

    private init() {
        MultipeerClient.shared.start()
    }
}
