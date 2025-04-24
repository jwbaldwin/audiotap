import SwiftUI

let kAppSubsystem = "com.jbaldwin.audiotap"

@main
struct AudioTapApp: App {
    var body: some Scene {
        WindowGroup {
            AudioTapView()
        }
    }
}
