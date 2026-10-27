import SwiftUI
import AppKit

@main
struct PhotoBackupCheckerApp: App {
    @State private var model: AppModel

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        let m = AppModel()
        _model = State(initialValue: m)
        if let dir = ProcessInfo.processInfo.environment["PBC_SNAPSHOT_DIR"], ProcessInfo.processInfo.environment["PBC_DEMO_PHONE"] != nil {
            Snapshot.start(dir: URL(fileURLWithPath: dir), model: m)
        }
    }

    var body: some Scene {
        WindowGroup("Photo Backup Checker") {
            ContentView(model: model).frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 840)
    }
}
