import SwiftUI

@main
struct DokaApp: App {
    @StateObject private var model = ViewfinderViewModel()

    var body: some Scene {
        WindowGroup {
            ViewfinderView(model: model)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
