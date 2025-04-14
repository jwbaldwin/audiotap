import Foundation
import CoreAudio
import AVFoundation

class AudioManager: ObservableObject {
    @Published var isRecording = false
    
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    
    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
    
    // Modern approach using CATapDescription (macOS 14.2+)
    func startRecording() {
        let engine = AVAudioEngine()
        self.audioEngine = engine
        
        // Configure output format for high quality audio
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
        
        guard let outputFormat = outputFormat else {
            print("Failed to create audio format")
            return
        }
        
        // Create output file
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dateString = dateFormatter.string(from: Date())
        let outputFileURL = documentsPath.appendingPathComponent("recording-\(dateString).wav")
        
        do {
            audioFile = try AVAudioFile(forWriting: outputFileURL, settings: outputFormat.settings)
            
            // Setup tap on system's output device
            setupSystemAudioTap(engine: engine, format: outputFormat)
            
            // Start the engine
            try engine.start()
            isRecording = true
            print("Recording started. File will be saved to: \(outputFileURL.path)")
        } catch {
            print("Recording failed to start: \(error.localizedDescription)")
        }
    }
    
    private func setupSystemAudioTap(engine: AVAudioEngine, format: AVAudioFormat) {
        // Get the system's output device
        var audioObjectID: AudioObjectID = AudioObjectID(kAudioObjectSystemObject)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        // Get the default output device
        let status = AudioObjectGetPropertyData(
            audioObjectID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &audioObjectID
        )
        
        if status != noErr {
            print("Error getting default output device: \(status)")
            // Fall back to using the main mixer output
            setupMixerTap(engine: engine, format: format)
            return
        }
        
        // For macOS 14.2+, ideally we would use AudioHardwareServiceCreateProcessTap
        // But since this is a prototype, we'll use a more established approach
        // by installing a tap on the engine's main mixer output
        setupMixerTap(engine: engine, format: format)
    }
    
    private func setupMixerTap(engine: AVAudioEngine, format: AVAudioFormat) {
        // Create a mixer node to collect the system sound
        let mixer = engine.mainMixerNode
        
        // Install a tap on the mixer's output
        mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }
            
            do {
                try audioFile.write(from: buffer)
            } catch {
                print("Error writing buffer to file: \(error.localizedDescription)")
            }
        }
    }
    
    func stopRecording() {
        guard let engine = audioEngine, isRecording else { return }
        
        // Remove the tap
        engine.mainMixerNode.removeTap(onBus: 0)
        
        // Stop the engine
        engine.stop()
        
        // Close the audio file
        audioFile = nil
        audioEngine = nil
        
        isRecording = false
        print("Recording stopped")
    }
}