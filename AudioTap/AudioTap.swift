import SwiftUI

@main
struct AudioTapApp: App {
    @StateObject private var audioService = AudioTapService()
    
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
        .onChange(of: audioService.errorMessage) { _, newValue in
            if let errorMessage = newValue {
                #if DEBUG
                print("Error: \(errorMessage)")
                #endif
            }
        }
        .onAppear {
            audioService.setupAudioSystem()
        }
    }
}