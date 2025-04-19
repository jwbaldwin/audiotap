import SwiftUI

struct AudioTapView: View {
    @ObservedObject var audioService: AudioTapService
    
    var body: some View {
        VStack(spacing: 12) {
            Text("AudioTap")
                .font(.headline)
            
            Divider()
            
            if audioService.isRecording {
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
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 200)
    }
}