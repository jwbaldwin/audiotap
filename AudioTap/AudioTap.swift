import SwiftUI

@main
struct AudioTapApp: App {
    // Use the shared singleton instance instead of creating a new one
    private var audioService = AudioTapService.shared
    
    init() {
            audioService.setupAudioSystem()
    }
    
    var body: some Scene {
        MenuBarExtra("AudioTap", systemImage: audioService.isRecording ? "record.circle.fill" : "record.circle") {
            AudioTapView(audioService: audioService)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Setup Audio System") {
                    audioService.setupAudioSystem()
                }
                .disabled(audioService.isSetup)
                
                Button("Teardown Audio System") {
                    audioService.tearDownAudioSystem()
                }
                .disabled(!audioService.isSetup)
            }
        }
    }
}
