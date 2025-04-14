import SwiftUI

@main
struct AudioTapApp: App {
    @StateObject private var audioManager = AudioManager()
    
    var body: some Scene {
        MenuBarExtra("AudioTap", systemImage: audioManager.isRecording ? "record.circle.fill" : "record.circle") {
            VStack(spacing: 12) {
                Text("AudioTap")
                    .font(.headline)
                
                Divider()
                
                if audioManager.isRecording {
                    Button("Stop Recording") {
                        audioManager.stopRecording()
                    }
                    .foregroundColor(.red)
                } else {
                    Button("Start Recording") {
                        audioManager.startRecording()
                    }
                    .foregroundColor(.blue)
                }
                
                Divider()
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding()
            .frame(width: 200)
        }
    }
}