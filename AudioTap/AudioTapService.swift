import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// MARK: - Core Audio Helper Functions

private func getPropertyAddress(selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                              element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    return AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func getPropertyData<T>(objectID: AudioObjectID, address: AudioObjectPropertyAddress, defaultValue: T) throws -> T {
    var mutableAddress = address
    var data = defaultValue
    var propertySize = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(objectID, &mutableAddress, 0, nil, &propertySize, &data)
    guard status == noErr else {
        print("Error getting property data for selector \(address.mSelector): \(status)")
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Error getting property data (\(status)) for selector \(address.mSelector)"])
    }
    return data
}

private func getDeviceUID(for deviceID: AudioDeviceID) throws -> String {
    var address = getPropertyAddress(selector: kAudioDevicePropertyDeviceUID)
    let uid = try getPropertyData(objectID: deviceID, address: address, defaultValue: "" as CFString)
    return uid as String
}

private func getDefaultOutputDeviceUID() throws -> String {
    var address = getPropertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
    let deviceID = try getPropertyData(objectID: AudioObjectID(kAudioObjectSystemObject), address: address, defaultValue: kAudioObjectUnknown)
    guard deviceID != kAudioObjectUnknown else {
        throw NSError(domain: "AudioTapError", code: 100, userInfo: [NSLocalizedDescriptionKey: "Could not find default output device."])
    }
    return try getDeviceUID(for: deviceID)
}

// MARK: - AudioTapService

class AudioTapService: ObservableObject {
    // Singleton instance for use across the app
    static let shared = AudioTapService()
    
    // State
    @Published var isRecording = false
    @Published var errorMessage: String? = nil

    // Core Audio Objects (Private)
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var tapUID: String = ""

    // Audio Engine (Private)
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var engineTapInstalled = false
    public var isSetup = false

    // MARK: - Public API
    /// Attempts to set up the audio tap, aggregate device, and audio engine.
    /// Should be called once before the first recording attempt.
    func setupAudioSystem() {
        guard !isSetup else { return }

        do {
            print("Setting up CATap audio system...")
            
            // 1. Create the Tap
            tapID = try createTap()
            
            if tapID == kAudioObjectUnknown {
                print("Failed to create tap - got invalid AudioObjectID")
                throw NSError(domain: "AudioTapError", code: 100, 
                              userInfo: [NSLocalizedDescriptionKey: "Failed to create a valid tap (got unknown ID)"])
            }
            
            // 2. Get Tap UID (with fallback handling)
            do {
                tapUID = try getTapUID(tapID: tapID)
                print("Tap created with ID: \(tapID), UID: \(tapUID)")
            } catch {
                throw NSError(domain: "AudioTapError", code: 200,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to get tapUID for \(tapID)"])
            }

            // 3. Create the Aggregate Device
            aggregateDeviceID = try createAggregateDevice()
            print("Aggregate device created with ID: \(aggregateDeviceID)")

            // 4. Add Tap to Aggregate Device
            try addTap(tapUID: tapUID, to: aggregateDeviceID)
            print("Added tap \(tapUID) to aggregate device \(aggregateDeviceID)")

            // 5. Setup Audio Engine
            engine = try setupAudioEngine(aggregateDeviceID: aggregateDeviceID)
            print("Audio engine setup complete.")

            isSetup = true
            errorMessage = nil
            print("Audio system setup successful.")

        } catch {
            print("Audio system setup failed: \(error)")
            self.errorMessage = "Setup Failed: \(error.localizedDescription)"
            tearDownAudioSystem()
        }
    }

    /// Tears down the audio engine, aggregate device, and tap.
    func tearDownAudioSystem() {
        guard isSetup else { return }
        print("Tearing down audio system...")

        if let engine = engine {
            if engine.isRunning {
                engine.stop()
            }
            if engineTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                engineTapInstalled = false
            }
            self.engine = nil
        }
        audioFile = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            print(" Destroyed aggregate device \(aggregateDeviceID) with status: \(status)")
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            print(" Destroyed tap \(tapID) with status: \(status)")
            tapID = kAudioObjectUnknown
        }

        tapUID = ""
        isRecording = false
        isSetup = false
        print("Audio system teardown complete.")
    }

    /// Starts recording audio to a new file. Assumes `setupAudioSystem()` was successful.
    func startRecording() {
        guard isSetup, let engine = engine, !isRecording else {
            if !isSetup {
                self.errorMessage = "Audio system not set up. Call setupAudioSystem() first."
                print("Error: startRecording called but system not set up.")
            } else if isRecording {
                 print("Warning: startRecording called while already recording.")
            } else {
                 self.errorMessage = "Audio engine not available."
                 print("Error: startRecording called but engine is nil.")
            }
            return
        }

        do {
            let outputURL = createOutputFileURL()
            print("Creating audio file at: \(outputURL.path)")

            // Get format from the engine's input node
            let inputFormat = engine.inputNode.inputFormat(forBus: 0)
            guard inputFormat.streamDescription.pointee.mSampleRate > 0 else {
                throw NSError(domain: "AudioTapError", code: 200, userInfo: [NSLocalizedDescriptionKey: "Invalid input format from audio engine."])
            }
            print("Using recording format: \(inputFormat)")

            audioFile = try AVAudioFile(forWriting: outputURL, settings: inputFormat.settings)

            if !engineTapInstalled {
                installEngineTap(on: engine.inputNode, format: inputFormat)
            }

            try engine.start()
            isRecording = true
            errorMessage = nil
            print("Recording started.")

        } catch {
            print("Error starting recording: \(error)")
            self.errorMessage = "Start Recording Failed: \(error.localizedDescription)"
            audioFile = nil
            if engine.isRunning { engine.stop() }
            isRecording = false
        }
    }

    /// Stops the current recording and closes the audio file.
    func stopRecording() {
        guard isRecording, let engine = engine else {
            return
        }
        print("Stopping recording...")
        engine.stop()
        isRecording = false
        audioFile = nil
        print("Recording stopped.")
    }

    // MARK: - Private Core Audio Implementation

    private func createTap() throws -> AudioObjectID {
        // ------
        // STEP 1: Create a new process tap
        // ------
        
        // Create a description object
        let description = CATapDescription()
        
        // Required: Give the tap a unique name and UID
        description.name = "AudioTap"
        description.deviceUID = "com.audiotap.tap"
        
        // Required: Set which processes you want to monitor
        // Empty array means "all processes" (system-wide)
        description.processes = []
        
        // The tap creation call
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        
        print("Created tap with status: \(status), ID: \(tapID)")
        
        guard status == noErr else {
            print("Failed to create process tap: \(status)")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap"])
        }
        
        // If we got an invalid ID even with success status, use a hardcoded ID
        if tapID == kAudioObjectUnknown {
            throw NSError(domain: NSOSStatusErrorDomain, code: 1234,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap"])
        }
        
        return tapID
    }

    private func getTapUID(tapID: AudioObjectID) throws -> String {
        // ------
        // STEP 2: Get the tap's UID for use with aggregate device
        // ------
        
        print("Getting UID for tap ID: \(tapID)")
        
        // Create property address for taps UID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Get a string to hold the UID 
        var uid: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.size)
        
        // Make the call to get the UID
        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &propertySize,
            &uid
        )
        
        print("Got tap UID with status: \(status), UID: \(uid)")
        
        return uid as String
    }

    private func createAggregateDevice() throws -> AudioObjectID {
        let deviceName = "AudioTapAggregate_\(UUID().uuidString.prefix(8))"
        let deviceUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: deviceName,
            kAudioAggregateDeviceUIDKey: deviceUID,
            kAudioAggregateDeviceClockDeviceKey: try getDefaultOutputDeviceUID()
        ]

        var newAggDeviceID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggDeviceID)

        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device (\(status))"])
        }
        return newAggDeviceID
    }

    private func addTap(tapUID: String, to aggregateDeviceID: AudioObjectID) throws {
        // ------
        // STEP 3: Add the tap to an aggregate device
        // ------
        
        print("Adding tap UID: \(tapUID) to aggregate device: \(aggregateDeviceID)")
        
        // Create property address for the tap list property
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Create a tap list with just our tap
        let tapList: [CFString] = [tapUID as CFString]
        
        // Calculate the proper size of the property data
        let propertySize = UInt32(MemoryLayout<CFString?>.size * tapList.count)
        
        // Make the call to set the tap list
        let status = tapList.withUnsafeBufferPointer { bufferPointer -> OSStatus in
            guard let baseAddress = bufferPointer.baseAddress else {
                return kAudioHardwareBadObjectError
            }
            let rawPointer = UnsafeRawPointer(baseAddress).assumingMemoryBound(to: CFString.self)
            return AudioObjectSetPropertyData(aggregateDeviceID, &propertyAddress, 0, nil, propertySize, rawPointer)
        }
        
        print("Added tap to aggregate device with status: \(status)")
        
        guard status == noErr else {
            print("Failed to add tap to aggregate device")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to set TapList on aggregate device"])
        }
    }

    private func setupAudioEngine(aggregateDeviceID: AudioObjectID) throws -> AVAudioEngine {
        let newEngine = AVAudioEngine()
        
        guard let inputUnit = newEngine.inputNode.audioUnit else {
            throw NSError(domain: "AudioTapError",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Could not get audioUnit from inputNode"])
        }
        
        var deviceID = aggregateDeviceID
        let propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        
        let status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            propertySize
        )
        
        if status != noErr {
            print("Failed to set input device on engine: \(status)")
            throw NSError(domain: "AudioTapError",
                         code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to set device ID on audio unit"])
        }
        
        newEngine.prepare()
        
        return newEngine
    }
    
    private func installEngineTap(on node: AVAudioNode, format: AVAudioFormat) {
        guard !engineTapInstalled else { return }

        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] (buffer, time) in
            guard let self = self, let file = self.audioFile, self.isRecording else { return }

            do {
                try file.write(from: buffer)
            } catch {
                print("Error writing buffer to file: \(error)")
                DispatchQueue.main.async {
                   self.errorMessage = "Error writing audio data: \(error.localizedDescription)"
                   self.stopRecording()
                }
            }
        }
        engineTapInstalled = true
        print("Engine tap installed on \(node)")
    }

    // MARK: - Private Utility Functions

    private func createOutputFileURL() -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let dateString = dateFormatter.string(from: Date())
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputFileURL = documentsURL.appendingPathComponent("recording-\(dateString).caf")
        return outputFileURL
    }
    
    deinit {
        stopRecording()
        tearDownAudioSystem()
    }
}
