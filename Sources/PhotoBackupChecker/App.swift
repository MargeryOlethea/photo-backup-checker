import SwiftUI
import AppKit

@main
struct PhotoBackupCheckerApp: App {
    @State private var model = AppModel()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("Photo Backup Checker") {
            ContentView(model: model).frame(minWidth: 820, minHeight: 560)
        }
    }
}
