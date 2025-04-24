import SwiftUI

let kAppSubsystem = "com.jbaldwin.audiotap"

@main
struct AudioTapApp: App {
    var body: some Scene {
        MenuBarExtra("Utility App", systemImage: "waveform") {
            AudioTapView()
        }
        .menuBarExtraStyle(.window)
    }
}
