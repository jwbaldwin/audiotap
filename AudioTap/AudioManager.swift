import Foundation
import CoreAudio
import AVFoundation
import AudioToolbox

class AudioManager: ObservableObject {
    @Published var isRecording = false
    
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var processTap: AudioObjectID?
    private var aggregateDevice: AudioObjectID?
    private var deviceIOProcID: AudioDeviceIOProcID?
    private var userDataRef: UnsafeMutableRawPointer?
    
    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
    
    // Output file URL for current recording
    private var outputFileURL: URL?
    
    // Storage structure to be passed to the device IO callback
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
        // Create storage for the IO callback
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
            mElement: kAudioObjectPropertyElementMain
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
        
        // Create an aggregate device with the output device
        do {
            if let aggDevice = try createAggregateDevice(withOutputDevice: deviceID) {
                aggregateDevice = aggDevice
                
                // Set up an IO proc on the aggregate device
                return setupDeviceIOProc()
            }
        } catch {
            print("Failed to create aggregate device: \(error.localizedDescription)")
        }
        
        return false
    }
    
    private func createAggregateDevice(withOutputDevice deviceID: AudioDeviceID) throws -> AudioObjectID? {
        // Create a unique device name and UID
        let deviceName = "AudioTap_\(UUID().uuidString.prefix(8))"
        let deviceUID = UUID().uuidString
        
        // Get device UID of the output device to use as clock source
        var outputDeviceUID = try getDeviceUID(for: deviceID)
        
        // Create the aggregate device description
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: deviceName,
            kAudioAggregateDeviceUIDKey: deviceUID,
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true
        ]
        
        var newAggDeviceID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggDeviceID)
        
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain,
                        code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device (\(status))"])
        }
        
        return newAggDeviceID
    }
    
    private func getDeviceUID(for deviceID: AudioDeviceID) throws -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceUIDRef: CFString?
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceUIDRef
        )
        
        guard status == noErr, let uid = deviceUIDRef as String? else {
            throw NSError(domain: NSOSStatusErrorDomain,
                        code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to get device UID"])
        }
        
        return uid
    }
    
    private func setupDeviceIOProc() -> Bool {
        guard let aggregateDevice = aggregateDevice else {
            return false
        }
        
        // Define the IO proc block - Fixed to match Swift's AudioDeviceIOBlock type signature
        // Define the IO proc block - Fixed to match Swift's AudioDeviceIOBlock type signature
        let ioProcBlock: AudioDeviceIOBlock = { inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            // Note the removed clientData parameter which was causing the error
            guard let audioFile = self.audioFile else { return }
            
            let ioData = outOutputData.pointee
            let bufferList = ioData.mBuffers
            let frames = ioData.mNumberBuffers > 0 ? bufferList.mDataByteSize / 4 : 0 // Assuming 32-bit float
            
            guard frames > 0 else { return }
            
            guard let format = self.audioFile?.processingFormat else { return }
            
            // Create a buffer to write to the file
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            
            // Fix optional unwrapping error for mData
            if let floatChannelData = buffer.floatChannelData, ioData.mNumberBuffers > 0 {
                let channelCount = min(Int(format.channelCount), Int(ioData.mNumberBuffers))
                
                for channel in 0..<channelCount {
                    // Fix to properly unwrap the optional mData pointer
                    if let mData = ioData.mBuffers.mData {
                        let audioBuffer = UnsafeRawPointer(mData)
                            .assumingMemoryBound(to: Float.self)
                        
                        for frame in 0..<Int(frames) {
                            floatChannelData[channel][frame] = audioBuffer[frame * channelCount + channel]
                        }
                    }
                }
                
                // Write to file
                do {
                    try audioFile.write(from: buffer)
                } catch {
                    print("Error writing to file: \(error.localizedDescription)")
                }
            }        }
        // Create the IO proc ID using the block
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDevice, nil, ioProcBlock)
        
        if status != noErr {
            print("Error creating IO proc: \(status)")
            return false
        }
        
        guard let deviceIOProcID = procID else {
            print("Failed to create IO proc ID")
            return false
        }
        
        self.deviceIOProcID = deviceIOProcID
        
        // Start the IO proc
        let startStatus = AudioDeviceStart(aggregateDevice, deviceIOProcID)
        if startStatus != noErr {
            print("Error starting audio device: \(startStatus)")
            cleanupIOProc()
            return false
        }
        
        return true
    }
    
    private func cleanupIOProc() {
        if let aggregateDevice = aggregateDevice, let deviceIOProcID = deviceIOProcID {
            AudioDeviceStop(aggregateDevice, deviceIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDevice, deviceIOProcID)
            self.deviceIOProcID = nil
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        // Stop and clean up the IO proc
        cleanupIOProc()
        
        // Destroy the aggregate device if it exists
        if let aggregateDevice = aggregateDevice {
            AudioHardwareDestroyAggregateDevice(aggregateDevice)
            self.aggregateDevice = nil
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
