import AVFAudio
import AVFoundation
import Accelerate
import AudioToolbox
import OSLog
import SwiftUI

@Observable
final class ProcessTap {

    typealias InvalidationHandler = (ProcessTap) -> Void

    let process: AudioProcess
    let muteWhenRunning: Bool
    private let logger: Logger

    private(set) var errorMessage: String? = nil

    init(process: AudioProcess, muteWhenRunning: Bool = false) {
        self.process = process
        self.muteWhenRunning = muteWhenRunning
        self.logger = Logger(
            subsystem: kAppSubsystem,
            category: "\(String(describing: ProcessTap.self))(\(process.name))")
    }

    @ObservationIgnored
    private var processTapID: AudioObjectID = .unknown
    @ObservationIgnored
    private var aggregateDeviceID = AudioObjectID.unknown
    @ObservationIgnored
    private var deviceProcID: AudioDeviceIOProcID?
    @ObservationIgnored
    private(set) var tapStreamDescription: AudioStreamBasicDescription?
    @ObservationIgnored
    private var invalidationHandler: InvalidationHandler?
    @ObservationIgnored
    private(set) var aggregateStreamDescription: AudioStreamBasicDescription?

    @ObservationIgnored
    private(set) var activated = false

    @MainActor
    func activate() {
        guard !activated else { return }
        activated = true

        logger.debug(#function)

        self.errorMessage = nil

        do {
            try prepare(for: process.objectID)
        } catch {
            logger.error("\(error, privacy: .public)")
            self.errorMessage = error.localizedDescription
        }
    }

    func invalidate() {
        guard activated else { return }
        defer { activated = false }

        logger.debug(#function)

        invalidationHandler?(self)
        self.invalidationHandler = nil

        if aggregateDeviceID.isValid {
            var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if err != noErr {
                logger.warning(
                    "Failed to stop aggregate device: \(err, privacy: .public)")
            }

            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(
                    aggregateDeviceID, deviceProcID)
                if err != noErr {
                    logger.warning(
                        "Failed to destroy device I/O proc: \(err, privacy: .public)"
                    )
                }
                self.deviceProcID = nil
            }

            err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr {
                logger.warning(
                    "Failed to destroy aggregate device: \(err, privacy: .public)"
                )
            }
            aggregateDeviceID = .unknown
        }

        if processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr {
                logger.warning(
                    "Failed to destroy audio tap: \(err, privacy: .public)")
            }
            self.processTapID = .unknown
        }
    }

    private func prepare(for objectID: AudioObjectID) throws {
        errorMessage = nil
        var tapDescription: CATapDescription

        if process.id == AudioTarget.systemWidePID {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [])
        } else {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [
                objectID
            ])

        }

        tapDescription.uuid = UUID()
        tapDescription.muteBehavior =
            muteWhenRunning ? .mutedWhenTapped : .unmuted
        var tapID: AUAudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard err == noErr else {
            errorMessage = "Process tap creation failed with error \(err)"
            return
        }

        logger.debug("Created process tap #\(tapID, privacy: .public)")

        self.processTapID = tapID

        let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readDeviceUID()

        let inputDeviceID = try AudioDeviceID.readDefaultSystemInputDevice()
        let inputDeviceUID = try inputDeviceID.readDeviceUID()

        let aggregateUID = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tap-\(process.id)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
                [kAudioSubDeviceUIDKey: inputDeviceUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]

        self.tapStreamDescription =
            try tapID.readAudioTapStreamBasicDescription()

        aggregateDeviceID = AudioObjectID.unknown
        err = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw "Failed to create aggregate device: \(err)"
        }
        
        do {
            self.aggregateStreamDescription = try self.aggregateDeviceID.readBasicStreamDescription(scope: kAudioDevicePropertyScopeOutput)
            if let aggDesc = self.aggregateStreamDescription {
                logger.debug("Aggregate device output ASBD: SampleRate: \(aggDesc.mSampleRate), Channels: \(aggDesc.mChannelsPerFrame), FormatID: \(aggDesc.mFormatID)")
            }
        } catch {
            logger.warning("Failed to read aggregate device output stream description: \(error)")
            // Fallback to tap stream description if aggregate fails, though this is less ideal
            self.aggregateStreamDescription = self.tapStreamDescription
        }

        logger.debug(
            "Created aggregate device #\(self.aggregateDeviceID, privacy: .public)"
        )
    }

    func run(
        on queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock,
        invalidationHandler: @escaping InvalidationHandler
    ) throws {
        assert(activated, "\(#function) called with inactive tap!")
        assert(
            self.invalidationHandler == nil,
            "\(#function) called with tap already active!")

        errorMessage = nil

        logger.debug("Run tap!")

        self.invalidationHandler = invalidationHandler

        var err = AudioDeviceCreateIOProcIDWithBlock(
            &deviceProcID, aggregateDeviceID, queue, ioBlock)
        guard err == noErr else {
            throw "Failed to create device I/O proc: \(err)"
        }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else { throw "Failed to start audio device: \(err)" }
    }

    deinit { invalidate() }

}

@Observable
final class ProcessTapRecorder {

    let fileURL: URL
    let process: AudioProcess
    private let queue = DispatchQueue(
        label: "ProcessTapRecorder", qos: .userInitiated)
    private let logger: Logger

    @ObservationIgnored
    private weak var _tap: ProcessTap?

    private(set) var isRecording = false

    init(fileURL: URL, tap: ProcessTap) {
        self.process = tap.process
        self.fileURL = fileURL
        self._tap = tap
        self.logger = Logger(
            subsystem: kAppSubsystem,
            category:
                "\(String(describing: ProcessTapRecorder.self))(\(fileURL.lastPathComponent))"
        )
    }

    private var tap: ProcessTap {
        get throws {
            guard let _tap else { throw "Process tab unavailable" }
            return _tap
        }
    }

    @ObservationIgnored
    private var currentFile: AVAudioFile?

    @MainActor
    func start() throws {
        logger.debug(#function)

        guard !isRecording else {
            logger.warning("\(#function, privacy: .public) while already recording")
            return
        }

        let tap = try tap
        if !tap.activated { tap.activate() }
        
        guard var streamDescription = tap.aggregateStreamDescription ?? tap.tapStreamDescription else {
              throw "Stream description not available from tap or aggregate device."
          }

        guard let format = AVAudioFormat(streamDescription: &streamDescription)
        else { throw "Failed to create AVAudioFormat." }

        logger.info("Using audio format: \(format, privacy: .public)")

        /*─────────── FIX #1 : full, explicit Linear-PCM settings ───────────*/
        let settings: [String: Any] = [
            AVFormatIDKey:                 kAudioFormatLinearPCM,
            AVSampleRateKey:               format.sampleRate,
            AVNumberOfChannelsKey:         format.channelCount,
            AVLinearPCMBitDepthKey:        32,
            AVLinearPCMIsFloatKey:         true,
            AVLinearPCMIsNonInterleaved:   !format.isInterleaved
        ]
        /*────────────────────────────────────────────────────────────────────*/

        let file = try AVAudioFile(forWriting: fileURL,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: format.isInterleaved)

        self.currentFile = file

        try tap.run(on: queue) { [weak self]
                                 inNow, inInputData, _, _, _ in
            guard let self, let currentFile = self.currentFile else { return }
            
            // Get pointers to buffer list
            let ablPtr = UnsafeMutablePointer<AudioBufferList>(mutating: inInputData)
            let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
            
            // DIAGNOSTIC: Detailed buffer inspection
            self.logger.debug("==== BUFFER ANALYSIS ====")
            self.logger.debug("Total buffers: \(buffers.count)")
            
            for i in 0..<buffers.count {
                let buffer = buffers[i]
                let bytesPerFrame = MemoryLayout<Float>.size * Int(buffer.mNumberChannels)
                let frameCount = Int(buffer.mDataByteSize) / bytesPerFrame
                
                self.logger.debug("Buffer[\(i)]: \(buffer.mNumberChannels) channels, \(buffer.mDataByteSize) bytes (\(frameCount) frames)")
                
                // Peek at some sample values
                if let floatPtr = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    var min: Float = 0
                    var max: Float = 0
                    var sum: Float = 0
                    
                    for j in 0..<Swift.min(frameCount * Int(buffer.mNumberChannels), 100) {
                        let sample = floatPtr[j]
                        min = Swift.min(min, sample)
                        max = Swift.max(max, sample)
                        sum += abs(sample)
                    }
                    
                    self.logger.debug("  Sample range: \(min) to \(max), avg magnitude: \(sum/Float(Swift.min(frameCount * Int(buffer.mNumberChannels), 100)))")
                }
            }
            
            // DIAGNOSTIC: Check file format
            self.logger.debug("File settings: \(currentFile.fileFormat.settings)")
            self.logger.debug("==== END ANALYSIS ====")
            
            guard var asbdForIOProc = tap.aggregateStreamDescription ?? tap.tapStreamDescription,
                  let formatForIOProc = AVAudioFormat(streamDescription: &asbdForIOProc)
            else {
                self.logger.error("Failed to get consistent format in IOProc")
                return
            }

            guard buffers.count >= 2 else { return }          // remote + mic required
            let remoteBuf   = buffers[0]
            let micBuf      = buffers[1]

            /*─────────── FIX #2 : compute common frame length ───────────*/
            let remoteFrames = Int(remoteBuf.mDataByteSize) /
                               (MemoryLayout<Float>.size * Int(remoteBuf.mNumberChannels))
            let micFrames    = Int(micBuf.mDataByteSize) /
                               (MemoryLayout<Float>.size * Int(micBuf.mNumberChannels))
            let mixFrames    = min(remoteFrames, micFrames)    // keep in-sync
            /*────────────────────────────────────────────────────────────*/

            /* allocate mix buffer */
            guard let mixPCM = AVAudioPCMBuffer(pcmFormat: formatForIOProc,
                                                frameCapacity: AVAudioFrameCount(mixFrames)) else {
                logger.error("Failed to allocate mix buffer")
                return
            }
            mixPCM.frameLength = AVAudioFrameCount(mixFrames)

            /* typed pointers */
            let remotePtr = remoteBuf.mData!.assumingMemoryBound(to: Float.self)
            let micPtr    = micBuf.mData!.assumingMemoryBound(to: Float.self)

            /*─────────── FIX #3 + #4 : channel policy & Accelerate mix ─────*/
            for ch in 0..<2 {                                      // output L & R
                let dst = mixPCM.floatChannelData![ch]

                /* copy MONO remote to both channels, or channel-match if stereo */
                let remoteSrc = remotePtr.advanced(by: ch < Int(remoteBuf.mNumberChannels)
                                                   ? ch * remoteFrames
                                                   : 0)
                memcpy(dst,
                       remoteSrc,
                       mixFrames * MemoryLayout<Float>.size)

                /* add MIC signal (duplicate if mic is mono) */
                let micSrc = micPtr.advanced(by: ch < Int(micBuf.mNumberChannels)
                                             ? ch * micFrames
                                             : 0)

                var scale: Float = 0.5                              // prevent clipping
                vDSP_vma(micSrc, 1, &scale, 0,
                         dst,    1,
                         dst,    1,
                         vDSP_Length(mixFrames))
            }
            /*────────────────────────────────────────────────────────────*/

            do    { try currentFile.write(from: mixPCM) }
            catch { logger.error("Write failed: \(error, privacy: .public)") }

        } invalidationHandler: { [weak self] _ in self?.handleInvalidation() }

        isRecording = true
    }

    func stop() {
        do {
            logger.debug(#function)

            guard isRecording else { return }

            currentFile = nil

            isRecording = false

            try tap.invalidate()
        } catch {
            logger.error("Stop failed: \(error, privacy: .public)")
        }
    }

    private func handleInvalidation() {
        guard isRecording else { return }

        logger.debug(#function)
    }

}
