import SwiftUI

@main
struct FolioApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.listen)
                .environment(model.entitlements)
                .task { await model.start() }
        }
    }
}
