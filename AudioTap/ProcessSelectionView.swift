import SwiftUI
import CoreAudio

@MainActor
struct ProcessSelectionView: View {
    @State private var processController = AudioProcessController()
    @State private var tap: ProcessTap?
    @State private var recorder: ProcessTapRecorder?
    @State private var coordinator: UploadCoordinator?
    @State private var store = RecordingHistoryStore()

    @State private var selectedProcess: AudioProcess?

    var body: some View {
        Section {
            Picker("Process", selection: $selectedProcess) {
                Text("Select…")
                    .tag(Optional<AudioProcess>.none)
                
                HStack {
                    Image(systemName: "speaker.wave.3")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                    
                    Text("System Audio (All Applications)")
                }
                .tag(Optional<AudioProcess>.some(createSystemAudioProcess()))

                ForEach(processController.processGroups) { group in
                    Section {
                        ForEach(group.processes) { process in
                            HStack {
                                Image(nsImage: process.icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 16, height: 16)

                                Text(process.name)
                            }
                                .tag(Optional<AudioProcess>.some(process))
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            .disabled(recorder?.isRecording == true)
            .task { processController.activate() }
            .onChange(of: selectedProcess) { oldValue, newValue in
                guard newValue != oldValue else { return }

                if let newValue {
                    setupRecording(for: newValue)
                } else if oldValue == tap?.process {
                    teardownTap()
                }
            }
        } header: {
            Text("Source")
                .font(.headline)
        }

        if let tap {
            if let errorMessage = tap.errorMessage {
                Text(errorMessage)
                    .font(.headline)
                    .foregroundStyle(.red)
            } else if let recorder, let coordinator {
                RecordingView(recorder: recorder, coordinator: coordinator)
                    .onChange(of: recorder.isRecording) { wasRecording, isRecording in
                        /// Each recorder instance can only record a single file, so we create a new file/recorder when recording stops.
                        if wasRecording, !isRecording {
                            createRecorder()
                        }
                    }
            }
        }
        
//        if let coordinator {
//            VStack {
//                ListRecordingsView(store: store, coordinator: coordinator)
//            }
//        }
    }

    private func setupRecording(for process: AudioProcess) {
        let newTap = ProcessTap(process: process)
        self.tap = newTap
        newTap.activate()

        createRecorder()
    }

    private func createRecorder() {
        guard let tap else { return }

        let filename = "\(tap.process.name)-\(Int(Date.now.timeIntervalSinceReferenceDate))"
        let audioFileURL = URL.applicationSupport.appendingPathComponent(filename, conformingTo: .wav)

        let newRecorder = ProcessTapRecorder(fileURL: audioFileURL, tap: tap)
        self.recorder = newRecorder
        
        self.coordinator = UploadCoordinator()
    }
    
    private func createSystemAudioProcess() -> AudioProcess {
        return AudioProcess(
            id: AudioTarget.systemWidePID,
            kind: .system, // You may need to add this kind
            name: "System Audio",
            audioActive: true,
            bundleID: nil,
            bundleURL: nil,
            objectID: AudioObjectID.unknown // Will be special-cased later
        )
    }

    private func teardownTap() {
        tap = nil
        recorder = nil
        coordinator = nil
    }
}

extension URL {
    static var applicationSupport: URL {
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let subdir = appSupport.appending(path: "AudioCap", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: subdir.path) {
                try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            }
            return subdir
        } catch {
            assertionFailure("Failed to get application support directory: \(error)")

            return FileManager.default.temporaryDirectory
        }
    }
}

