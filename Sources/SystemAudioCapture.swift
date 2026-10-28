import AVFoundation
import AudioToolbox
import CoreAudio

/// The other people's side of a meeting: whatever the Mac plays (Zoom, Meet, Teams, a call in
/// the browser), captured with a Core Audio process tap (macOS 14.4+), the same mechanism
/// meeting note-takers like Granola use. No screen recording is involved; macOS asks once for
/// permission to record system audio (NSAudioCaptureUsageDescription).
///
///   CATapDescription        a global stereo tap of every process except Starlight (its own sounds)
///   AudioHardwareCreateProcessTap
///   aggregate device        the default output as its clock, with the tap as an input
///   IOProc                  hands each buffer on, still in the tap's format
///
/// When the default output changes (headphones connect), the tap is rebuilt on the new device.
final class SystemAudioCapture {
    /// Called on the capture queue; the buffer is only valid during the call.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var isRunning = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "notch.system-audio", qos: .userInitiated)
    private var outputListener: AudioObjectPropertyListenerBlock?

    enum Failure: LocalizedError {
        case tap(OSStatus), format(OSStatus), aggregate(OSStatus), ioProc(OSStatus), start(OSStatus), noOutput
        var errorDescription: String? {
            switch self {
            case .tap(let s): "Couldn't create the audio tap (\(s))"
            case .format(let s): "Couldn't read the tap format (\(s))"
            case .aggregate(let s): "Couldn't create the capture device (\(s))"
            case .ioProc(let s): "Couldn't attach to the capture device (\(s))"
            case .start(let s): "Couldn't start capturing (\(s)); system audio recording may be off for Starlight"
            case .noOutput: "No audio output device"
            }
        }
    }

    /// Start, stop and rebuilds all happen here, one at a time, so a rebuild for new headphones
    /// can't finish after a stop and leave a tap running.
    private let control = DispatchQueue(label: "notch.system-audio.control")
    /// Set if a rebuild failed: the tap is gone though the session wants it.
    var onFailure: (() -> Void)?

    func start() throws {
        try control.sync {
            guard !isRunning else { return }
            try build()
            isRunning = true
            listenForOutputChanges()
        }
    }

    func stop() {
        control.sync {
            guard isRunning else { return }
            isRunning = false
            stopListening()
            teardown()
        }
    }

    // MARK: Tap and aggregate device

    private func build() throws {
        let excluded = Self.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Starlight meeting audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted  // you still hear the meeting

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure.tap(status) }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            teardown()
            throw Failure.format(status)
        }
        self.format = format

        guard let outputUID = Self.defaultOutputUID() else { teardown(); throw Failure.noOutput }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Starlight meeting audio",
            kAudioAggregateDeviceUIDKey: "com.starlightnotch.app.tap." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else { teardown(); throw Failure.aggregate(status) }
        aggregateID = aggregate

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [weak self] _, input, _, _, _ in
            guard let self, let format = self.format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            if Self.debugLevels { self.logLevel(buffer) }
            self.onBuffer?(buffer)
        }
        guard status == noErr else { teardown(); throw Failure.ioProc(status) }

        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { teardown(); throw Failure.start(status) }
        DebugLog.write("system audio: tapping \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, output \(outputUID)")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        format = nil
    }

    // MARK: Debug

    /// STARLIGHT_DEBUG_TAP=1 logs the tap's peak level every 2 s (0 means silence: usually no
    /// permission to record system audio).
    private static let debugLevels = Dev.env("STARLIGHT_DEBUG_TAP") != nil
    private var peak: Float = 0
    private var lastLevelLog = Date()

    private func logLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[i])) }
        guard Date().timeIntervalSince(lastLevelLog) > 2 else { return }
        DebugLog.write(String(format: "system audio: peak %.4f", peak))
        peak = 0
        lastLevelLog = Date()
    }

    // MARK: Output changes

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func listenForOutputChanges() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            // Bluetooth outputs take a moment to settle, like the microphone side.
            self.control.asyncAfter(deadline: .now() + 0.6) {
                guard self.isRunning else { return }
                DebugLog.write("system audio: output changed, rebuilding the tap")
                self.teardown()
                do { try self.build() } catch {
                    DebugLog.write("system audio: rebuild failed: \(error.localizedDescription)")
                    self.isRunning = false
                    self.stopListening()
                    self.onFailure?()
                }
            }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, block)
    }

    private func stopListening() {
        guard let block = outputListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, block)
        outputListener = nil
    }

    // MARK: Queries

    private static func defaultOutputUID() -> String? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// Starlight's own Core Audio process object, so its sounds aren't captured as "them".
    private static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
