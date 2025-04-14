import Foundation
import CoreAudio
import AVFoundation
import AudioToolbox

class AudioManager: ObservableObject {
    @Published var isRecording = false
    
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var processTap: CATapRef?
    private var userDataRef: UnsafeMutableRawPointer?
    
    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
    
    // Output file URL for current recording
    private var outputFileURL: URL?
    
    // Storage structure to be passed to the tap callback
    struct TapStorage {
        var audioFile: AVAudioFile?
        var format: AVAudioFormat?
    }
    
    deinit {
        stopRecording()
    }
    
    func startRecording() {
        // Configure output format for high quality audio
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
        
        guard let outputFormat = outputFormat else {
            print("Failed to create audio format")
            return
        }
        
        // Create output file
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dateString = dateFormatter.string(from: Date())
        outputFileURL = documentsPath.appendingPathComponent("recording-\(dateString).wav")
        
        guard let outputFileURL = outputFileURL else {
            print("Failed to create output file URL")
            return
        }
        
        do {
            // Create the audio file for recording
            audioFile = try AVAudioFile(forWriting: outputFileURL, settings: outputFormat.settings)
            
            // Create an audio engine instance for processing
            let engine = AVAudioEngine()
            self.audioEngine = engine
            
            // Setup system audio tap
            if setupSystemAudioTap(format: outputFormat) {
                isRecording = true
                print("Recording started. File will be saved to: \(outputFileURL.path)")
            } else {
                print("Failed to setup system audio tap")
                audioFile = nil
                audioEngine = nil
                isRecording = false
            }
        } catch {
            print("Recording failed to start: \(error.localizedDescription)")
        }
    }
    
    private func setupSystemAudioTap(format: AVAudioFormat) -> Bool {
        // Create storage for the tap callback
        var tapStorage = TapStorage(audioFile: audioFile, format: format)
        
        // Convert to UnsafeMutableRawPointer to pass to the C API
        let tapStoragePointer = UnsafeMutablePointer<TapStorage>.allocate(capacity: 1)
        tapStoragePointer.initialize(to: tapStorage)
        userDataRef = UnsafeMutableRawPointer(tapStoragePointer)
        
        // Get the default output device
        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        if status != noErr {
            print("Error getting default output device: \(status)")
            return false
        }
        
        // Create the tap description
        var tapDescription = CATapDescription()
        tapDescription.device = deviceID
        tapDescription.flags = 0  // No special flags needed
        
        // Set the format from our AVAudioFormat
        guard let streamDescription = format.streamDescription else {
            print("Failed to get stream description from format")
            return false
        }
        tapDescription.format = streamDescription.pointee
        
        // Set up the tap callback function
        let tapCallback: CATapCallback = { (clientData, tap, frames, audioData) -> OSStatus in
            guard let userData = clientData else { return noErr }
            
            // Retrieve our storage structure
            let tapStoragePointer = userData.assumingMemoryBound(to: TapStorage.self)
            guard let audioFile = tapStoragePointer.pointee.audioFile else { return noErr }
            
            // Get format information from the audio data
            let format = audioData.pointee.format
            let bufferList = audioData.pointee.bufferList
            
            // Create an AVAudioPCMBuffer to write to the file
            guard let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(format.mSampleRate),
                channels: AVAudioChannelCount(format.mChannelsPerFrame),
                interleaved: false) else {
                return noErr
            }
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else {
                return noErr
            }
            
            buffer.frameLength = AVAudioFrameCount(frames)
            
            // Copy audio data from the buffer list to our AVAudioPCMBuffer
            let channelCount = Int(format.mChannelsPerFrame)
            
            // Get pointer to the first buffer in the buffer list
            if channelCount > 0 && bufferList.pointee.mNumberBuffers > 0 {
                let audioBuffer = bufferList.pointee.mBuffers
                
                if let floatChannelData = buffer.floatChannelData {
                    let dataPtr = audioBuffer.mData?.assumingMemoryBound(to: Float.self)
                    
                    if let dataPtr = dataPtr {
                        // Copy the data - this example assumes non-interleaved format
                        // For proper implementation, you'd need to handle both interleaved and non-interleaved formats
                        for frame in 0..<Int(frames) {
                            if frame < Int(buffer.frameCapacity) {
                                floatChannelData[0][frame] = dataPtr[frame]
                                
                                // For stereo, copy the second channel data if available
                                if channelCount > 1 && bufferList.pointee.mNumberBuffers > 1 {
                                    let secondBuffer = bufferList.advanced(by: 1).pointee.mBuffers
                                    let secondDataPtr = secondBuffer.mData?.assumingMemoryBound(to: Float.self)
                                    if let secondDataPtr = secondDataPtr {
                                        floatChannelData[1][frame] = secondDataPtr[frame]
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Write the buffer to the audio file
            do {
                try audioFile.write(from: buffer)
            } catch {
                print("Error writing to file: \(error.localizedDescription)")
            }
            
            return noErr
        }
        
        // Create the audio tap
        var tap: CATapRef?
        let tapStatus = AudioHardwareCreateProcessTap(&tapDescription, tapCallback, userDataRef, &tap)
        
        if tapStatus != noErr {
            print("Error creating audio tap: \(tapStatus)")
            return false
        }
        
        guard let createdTap = tap else {
            print("Failed to create tap")
            return false
        }
        
        processTap = createdTap
        return true
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        // Destroy the audio tap
        if let tap = processTap {
            AudioHardwareDestroyProcessTap(tap)
            processTap = nil
        }
        
        // Free the user data
        if let userDataRef = userDataRef {
            userDataRef.deallocate()
            self.userDataRef = nil
        }
        
        // Clean up the audio engine
        audioEngine?.stop()
        audioEngine = nil
        
        // Close the audio file
        audioFile = nil
        
        isRecording = false
        print("Recording stopped")
        
        if let outputFileURL = outputFileURL {
            print("Recording saved to: \(outputFileURL.path)")
        }
    }
}