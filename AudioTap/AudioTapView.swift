import SwiftUI

struct AudioTapView: View {
    @ObservedObject var audioService: AudioTapService
    
    var body: some View {
        VStack(spacing: 12) {
            Text("AudioTap")
                .font(.headline)
            
            Divider()
            
            if let error = audioService.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if audioService.isRecording {
                Button("Stop Recording") {
                    audioService.stopRecording()
                }
                .foregroundColor(.red)
            } else {
                Button("Start Recording") {
                    audioService.startRecording()
                }
                .foregroundColor(.blue)
            }
            
            Divider()
            
            if audioService.isSetup {
                Text("System Ready")
                    .foregroundColor(.green)
                    .font(.caption)
            } else {
                Button("Setup Audio") {
                    audioService.setupAudioSystem()
                }
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