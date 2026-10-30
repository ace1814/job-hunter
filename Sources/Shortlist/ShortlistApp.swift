import SwiftUI

@main
struct ShortlistApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Shortlist", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
    }
}
