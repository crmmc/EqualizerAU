import SwiftUI

enum M1RuntimeBootstrap {
    static var abiVersion: UInt32 {
        EAUM1RuntimeABIVersion()
    }
}

@main
struct EqualizerAUM1App: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("EqualizerAU M1")
                    .font(.title2)
                Text("System processing is stopped")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(minWidth: 420, minHeight: 240, alignment: .topLeading)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 320)
    }
}
