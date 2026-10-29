import SwiftUI

@main
struct LogPhotoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DebugLog.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            let name: String
            switch newPhase {
            case .active: name = "active"
            case .inactive: name = "inactive"
            case .background: name = "background"
            @unknown default: name = "unknown"
            }
            DebugLog.shared.scenePhaseChanged(name)
        }
    }
}
