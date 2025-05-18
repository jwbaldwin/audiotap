import SwiftUI

@MainActor
struct RecordingView: View {
    let recorder: ProcessTapRecorder
    @ObservedObject var coordinator: UploadCoordinator

    @State private var lastRecordingURL: URL?

    var body: some View {
        Section {
            HStack {
                if recorder.isRecording {
                    Button("Stop") {
                        recorder.stop()
                    }
                    .id("button")
                } else {
                    Button("Start") {
                        handlingErrors { try recorder.start() }
                    }
                    .id("button")

                    if let lastRecordingURL {
                        HStack {
                            FileProxyView(url: lastRecordingURL)
                            if coordinator.isUploading {
                                ProgressView(value: coordinator.uploadProgress)
                                    .progressViewStyle(.linear)
                                    .frame(width: 80)
                                
                                Text("\(Int(coordinator.uploadProgress * 100))%")
                                                                    .font(.caption)
                            } else {
                                Button("Upload") {
                                    Task {
                                        await coordinator.uploadRecording(fileURL: lastRecordingURL)
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.smooth, value: recorder.isRecording)
            .animation(.smooth, value: lastRecordingURL)
            .onChange(of: recorder.isRecording) { _, newValue in
                if !newValue {
                    lastRecordingURL = recorder.fileURL
                    // Start the upload
                    Task { await coordinator.uploadRecording(fileURL: recorder.fileURL) }
                }
            }
        } header: {
            HStack {
                RecordingIndicator(appIcon: recorder.process.icon, isRecording: recorder.isRecording)

                Text(recorder.isRecording ? "Recording from \(recorder.process.name)" : "Ready to Record from \(recorder.process.name)")
                    .font(.headline)
                    .contentTransition(.identity)
            }
        }
    }

    private func handlingErrors(perform block: () throws -> Void) {
        do {
            try block()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
