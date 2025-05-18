import Foundation
import SwiftUI

@MainActor
final class UploadCoordinator: ObservableObject {
    
    @Published var isUploading = false
    @Published var uploadProgress = 0.0
    @Published var lastError: Error?
    
    private let uploader: AudioUploading
    
    init(uploader: AudioUploading = AudioUploader()) {
        self.uploader = uploader
    }
    
    func uploadRecording(fileURL: URL) async {
        guard !isUploading else { return }
        
        isUploading = true
        uploadProgress = 0
        lastError = nil
        
        do {
            let response = try await uploader.upload(fileURL: fileURL) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.uploadProgress = progress
                }
            }
            print("Upload successful: \(response.data)")
        } catch {
            lastError = error
        }
        
        isUploading = false
    }
}

