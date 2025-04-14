import SwiftUI // Or AppKit if preferred
import AVFoundation
import CoreAudio
import AudioToolbox // Needed for some constants

class AudioTapEngineManager: ObservableObject {

    // State
    @Published var isRecording = false
    @Published var errorMessage: String? = nil

    // Core Audio Objects
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var tapUUID: UUID? = nil

    // Audio Engine
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var inputNodeTapInstalled = false

    // --- Setup & Teardown ---

    func setup() {
        do {
            try createTap()
            try createAggregateDevice()
            try addTapToAggregateDevice()
            try setupAudioEngine()
        } catch {
            print("Setup failed: \(error)")
            self.errorMessage = "Setup Failed: \(error.localizedDescription)"
            // Perform cleanup if setup partially succeeded
            tearDown()
        }
    }

    func tearDown() {
        // Stop engine first if running
        if engine?.isRunning ?? false {
            engine?.stop()
        }
        if inputNodeTapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            inputNodeTapInstalled = false
        }
        engine = nil
        audioFile = nil // Close file

        // Destroy Core Audio objects in reverse order of creation
        if aggregateDeviceID != kAudioObjectUnknown {
            destroyAggregateDevice()
        }
        if tapID != kAudioObjectUnknown {
            destroyTap()
        }
        isRecording = false
        print("Teardown complete.")
    }

    // --- Recording Control ---

    func startRecording() {
        guard !isRecording else { return }
        guard engine != nil, aggregateDeviceID != kAudioObjectUnknown, tapID != kAudioObjectUnknown else {
             print("Setup not complete or failed previously. Attempting setup again.")
             setup() // Try to setup again if needed
             // Check again if setup succeeded this time
             guard engine != nil, aggregateDeviceID != kAudioObjectUnknown, tapID != kAudioObjectUnknown else {
                 self.errorMessage = "Audio setup failed. Cannot start recording."
                 print("Audio setup failed. Cannot start recording.")
                 return
             }
         }

        do {
            // Create output file
            let outputURL = createOutputFileURL()
            // Get the format from the engine's input node AFTER aggregate device is likely set
             guard let inputFormat = engine?.inputNode.inputFormat(forBus: 0),
                   inputFormat.streamDescription.pointee.mSampleRate > 0 // Ensure format is valid
             else {
                 throw NSError(domain: "AudioTapError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not get valid input format from audio engine."])
             }
            
            print("Attempting to write to URL: \(outputURL.path)")
            print("Using format: \(inputFormat)")

            audioFile = try AVAudioFile(forWriting: outputURL, settings: inputFormat.settings, commonFormat: inputFormat.commonFormat, interleaved: inputFormat.isInterleaved)

            // Ensure tap is installed before starting engine
             if !inputNodeTapInstalled {
                 installEngineTap(format: inputFormat)
             }

            // Start the engine
            try engine?.start()
            isRecording = true
            errorMessage = nil
            print("Recording started.")

        } catch {
            print("Error starting recording: \(error)")
            self.errorMessage = "Start Recording Failed: \(error.localizedDescription)"
            // Cleanup partial setup if file creation failed etc.
            audioFile = nil
            if engine?.isRunning ?? false { engine?.stop() }
            isRecording = false
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        engine?.stop()
        isRecording = false
        // File is closed when audioFile is set to nil during teardown or next recording start
        // Keep engine/devices alive until explicitly torn down or next recording cycle
        print("Recording stopped.")
        // Consider whether to automatically call tearDown() here or keep setup alive
         tearDown() // Call teardown to clean up devices immediately after stopping
    }


    // --- Core Audio Implementation ---

    private func createTap() throws {
        // 1. Create Tap Description
        let description = CATapDescription()
        description.name = "MyAudioTap_\(UUID().uuidString)" // Unique name recommended
        description.uuid = UUID()
        self.tapUUID = description.uuid // Store for later use

        // Configure what the tap captures (e.g., specific process or system-wide)
        description.processes = [] // Example: Tap only this app's process ID
        // Or for system-wide audio (excluding muted processes):
        // description.processes = [] // Empty array means system-wide (check documentation for specifics)

        // Note: Other properties like muteBehavior, tapScope can be set here.
        // description.muteBehavior = .mute // Example: Mutes the tapped audio
        // description.tapScope = .output // Example: Tap output audio

        print("Creating tap with UUID: \(String(describing: self.tapUUID))")

        // 2. Create the Tap
        var newTapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(description, &newTapID)

        guard status == noErr else {
            print("Failed to create tap: \(status)")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap (\(status))"])
        }

        self.tapID = newTapID
        print("Tap created successfully with ID: \(self.tapID)")
    }

    private func destroyTap() {
        guard tapID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            print("Error destroying tap \(tapID): \(status)")
        } else {
            print("Tap \(tapID) destroyed successfully.")
        }
        tapID = kAudioObjectUnknown
    }

    private func createAggregateDevice() throws {
        // 1. Create Aggregate Device Description Dictionary
        let deviceName = "MyTapAggregateDevice_\(UUID().uuidString)"
        let deviceUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: deviceName,
            kAudioAggregateDeviceUIDKey: deviceUID,
            // Important: Specify the main output device as the clock source
            // This ensures the aggregate device syncs correctly. Let's find the default output.
            kAudioAggregateDeviceClockDeviceUIDKey: try getDefaultOutputDeviceUID() ?? ""
            // kAudioAggregateDeviceIsPrivateKey: true // Optionally make it private
        ]

        print("Creating aggregate device named: \(deviceName)")

        // 2. Create the Aggregate Device
        var newAggDeviceID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggDeviceID)

        guard status == noErr else {
            print("Failed to create aggregate device: \(status)")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device (\(status))"])
        }
        self.aggregateDeviceID = newAggDeviceID
        print("Aggregate device created successfully with ID: \(self.aggregateDeviceID)")
    }

    private func destroyAggregateDevice() {
        guard aggregateDeviceID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        if status != noErr {
            print("Error destroying aggregate device \(aggregateDeviceID): \(status)")
        } else {
            print("Aggregate device \(aggregateDeviceID) destroyed successfully.")
        }
        aggregateDeviceID = kAudioObjectUnknown
    }

    private func addTapToAggregateDevice() throws {
        guard tapID != kAudioObjectUnknown, aggregateDeviceID != kAudioObjectUnknown, ((tapUUID?.uuid) != nil) else {
            print("Missing tapID, aggregateDeviceID, or tapUUID")
            throw NSError(domain: "AudioTapError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required IDs for adding tap to aggregate device."])
        }

        // 1. Get the current list of sub-devices (including taps) for the aggregate device
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList, // <- Use TapList for taps
            mScope: kAudioObjectPropertyScopeOutput, // Scope depends on how you configure the aggregate
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(aggregateDeviceID, &propertyAddress, 0, nil, &propertySize)
        guard status == noErr else {
             print("Error getting size for TapList: \(status)")
             throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey:"Error getting size for TapList (\(status))"])
         }

        // Even if empty, proceed to set our tap UID
        
        // 2. Set the tap list property with our tap's UID
        var tapUUIDCFString = tapUUID as! CFString
        let tapList: [CFString] = [tapUUIDCFString] // List containing only our tap UID
        propertySize = UInt32(MemoryLayout<CFString?>.size * tapList.count) // Correct size calculation

        print("Attempting to add tap UID \(String(describing: tapUUID)) to aggregate device \(aggregateDeviceID)")

        status = withUnsafePointer(to: tapList) { ptr -> OSStatus in
            // Need to bridge the Swift array pointer correctly
            let arrayPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: CFString.self)
            return AudioObjectSetPropertyData(aggregateDeviceID, &propertyAddress, 0, nil, propertySize, arrayPtr)
        }
        // --- Check status ---
         guard status == noErr else {
             print("Error setting TapList: \(status)")
             // Provide more context if possible
             let userInfo: [String: Any] = [
                 NSLocalizedDescriptionKey: "Failed to set TapList on aggregate device (\(status)). Ensure tap UID is correct and tap exists.",
                 "tapUUID": tapUUID!,
                 "AggregateDeviceID": aggregateDeviceID
             ]
             throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: userInfo)
         }


        print("Successfully added tap \(tapID) (UID: \(String(describing: tapUUID))) to aggregate device \(aggregateDeviceID)")
    }


    private func setupAudioEngine() throws {
        engine = AVAudioEngine()
        guard let engine = engine else {
            throw NSError(domain: "AudioTapError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize AVAudioEngine."])
        }

        // Find the AVAudioDevice corresponding to our aggregate device ID
        guard let aggregateAVDevice = findAVAudioDevice(by: aggregateDeviceID) else {
             print("Could not find AVAudioDevice for aggregate device ID: \(aggregateDeviceID)")
             throw NSError(domain: "AudioTapError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not find the created aggregate audio device (\(aggregateDeviceID)) within AVAudioSession/AVAudioEngine."])
         }

         print("Found AVAudioDevice: \(aggregateAVDevice.name ?? "Unknown Name") with UID: \(aggregateAVDevice.uid ?? "No UID") for ID \(aggregateDeviceID)")


        // Try setting the engine's input node to use our aggregate device
        do {
            try engine.inputNode setDeviceID(aggregateDeviceID) // Use the AudioObjectID directly
            print("Successfully set engine input device to aggregate device ID: \(aggregateDeviceID)")
        } catch {
             print("Error setting device ID on input node: \(error)")
             throw NSError(domain: "AudioTapError", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to set input device on AVAudioEngine: \(error.localizedDescription)"])
         }

        // Now install the tap on the engine's input node
        // Format is determined AFTER setting the device
         guard let inputFormat = engine.inputNode.inputFormat(forBus: 0),
               inputFormat.streamDescription.pointee.mSampleRate > 0 else {
            print("Could not get valid input format after setting device.")
            throw NSError(domain: "AudioTapError", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not get valid input format from input node after setting device."])
        }
         print("Engine input node format: \(inputFormat)")
         
         if !inputNodeTapInstalled {
            installEngineTap(format: inputFormat)
         }

        engine.prepare()
        print("Audio engine prepared.")
    }

    private func installEngineTap(format: AVAudioFormat) {
         guard let engine = engine else { return }

         engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] (buffer, time) in
             guard let self = self, let file = self.audioFile else { return }
            
             do {
                 try file.write(from: buffer)
             } catch {
                 // Non-fatal, but log it. Stop recording if errors persist?
                 print("Error writing buffer to file: \(error)")
                 // Consider setting self.errorMessage or stopping recording here
                 // DispatchQueue.main.async { self.errorMessage = "Error writing audio data." }
                 // self.stopRecording()
             }
         }
         inputNodeTapInstalled = true
         print("Audio engine tap installed on input node.")
     }


    // --- Utility Functions ---

    private func createOutputFileURL() -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let dateString = dateFormatter.string(from: Date())
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputFileURL = documentsPath.appendingPathComponent("recording-\(dateString).wav") // Use .wav or .caf
        return outputFileURL
    }
    
    private func getDefaultOutputDeviceUID() throws -> String? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
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
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        
        // Now get the UID for this deviceID
        return try getDeviceUID(for: deviceID)
    }

    private func getDeviceUID(for deviceID: AudioDeviceID) throws -> String? {
        var uid: CFString? = nil
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &uid
        )
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        
        return uid as String?
    }
}

// MARK: - Simple SwiftUI View Example

struct ContentView: View {
    @StateObject private var audioManager = AudioTapEngineManager()

    var body: some View {
        VStack {
            Text("System Audio Tap Recorder")
                .font(.title)

            if audioManager.isRecording {
                Button("Stop Recording") {
                    audioManager.stopRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button("Start Recording") {
                    // Ensure setup is done before starting (could be done onAppear)
                    // audioManager.setup() // Call setup explicitly if not done elsewhere
                    audioManager.startRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            if let errorMsg = audioManager.errorMessage {
                Text("Error: \(errorMsg)")
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .padding()
        .onAppear {
            // Setup when the view appears
             audioManager.setup()
        }
        .onDisappear {
            // Clean up when the view disappears
            audioManager.tearDown()
        }
    }
}
