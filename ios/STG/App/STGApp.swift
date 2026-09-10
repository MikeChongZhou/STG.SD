import SwiftUI

@main
struct STGApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { RootView(model: model) }
            .onChange(of: scenePhase) { _, phase in
                SharedEnvironment.diagnosticLog.record("scene phase: \(String(describing: phase))", category: "lifecycle")
                if phase == .background { model.scheduleBackgroundRefresh() }
            }
    }
}
