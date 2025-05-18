import SwiftUI

@MainActor
final class RecordingHistoryStore: ObservableObject {
    @Published private(set) var items: [RecordingHistoryItem] = []
    
    // Keep only the latest 100 on disk, show 5 at once.
    private let maxStored = 100
    
    func add(_ fileURL: URL, uploaded: Bool = false) {
        items.insert(.init(fileURL: fileURL,
                           timestamp: Date(),
                           uploaded: uploaded),
                     at: 0)
        items = Array(items.prefix(maxStored))
    }

    func markUploaded(_ id: RecordingHistoryItem.ID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].uploaded = true
    }
}
