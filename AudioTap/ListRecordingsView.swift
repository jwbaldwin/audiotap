import SwiftUI
import Foundation

struct RecordingHistoryItem: Identifiable, Equatable {
    let id          = UUID()
    let fileURL     : URL
    let timestamp   : Date
    var uploaded    : Bool
}

struct ListRecordingsView: View {
    
    @ObservedObject var store      : RecordingHistoryStore
    var coordinator                : UploadCoordinator
    
    private let rowHeight: CGFloat = 24
    
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Recordings")
                .font(.headline)
                .padding(.horizontal)
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.items) { item in
                        RecordingRow(item: item) {
                            handleButtonTap(item)
                        }
                        Divider()
                    }
                }
            }
            .frame(height: rowHeight * 5)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding()
    }
    
    
    private func handleButtonTap(_ item: RecordingHistoryItem) {
        Task {
            await coordinator.uploadRecording(fileURL: item.fileURL)
            store.markUploaded(item.id)
        }
    }
}

private struct RecordingRow: View {
    let item         : RecordingHistoryItem
    let actionTapped : () -> Void
    
    var body: some View {
        HStack {
            Text(item.fileURL.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            Text(item.timestamp, style: .time)
                .foregroundStyle(.secondary)
                .font(.footnote)
            
            Button(item.uploaded ? "Re-upload" : "Upload",
                   action: actionTapped)
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.horizontal)
        .frame(height: 24)
    }
}
