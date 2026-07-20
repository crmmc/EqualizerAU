import SwiftUI

@main
struct EqualizerAUApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 520, minHeight: 320)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 620, height: 360)
    }
}
