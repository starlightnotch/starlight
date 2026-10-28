import AVFoundation
import CoreAudio
import AudioToolbox
import IOKit

/// Microphone capture. Instead of AVAudioEngine it runs an input-only HAL audio unit bound to
/// one input device:
///
///   kAudioOutputUnitProperty_EnableIO        input scope, element 1 = on; output scope, element 0 = off
///   kAudioOutputUnitProperty_CurrentDevice   the input device
///   kAudioUnitProperty_StreamFormat          read the device format, set a Float32 client format
///   kAudioUnitProperty_MaximumFramesPerSlice preallocate the render buffer
///   kAudioOutputUnitProperty_SetInputCallback pull audio with AudioUnitRender
///
/// With no output side, sounds or Bluetooth headphones changing the output route can't stop it
/// (the AVAudioEngine version went silent whenever a sound played on AirPods). It listens for the default input device changing, waits for Bluetooth inputs to settle, and runs
/// a health check that restarts the unit if callbacks stop.
final class AudioCapture {
    let normalizer: LevelNormalizer
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevels: (([Int]) -> Void)?
    /// Called on the main thread when the microphone delivers nothing even after restarts.
    var onSilentInput: (() -> Void)?
    private(set) var isRunning = false
    private(set) var deviceName = ""

    private var unit: AudioUnit?
    private var deviceID = AudioDeviceID(0)
    private var renderBuffer: AVAudioPCMBuffer?
    private var lastLevelUpdate: CFAbsoluteTime = 0
    /// Levels go out at most 30 times a second; the bars animate between updates.
    private let levelInterval: CFAbsoluteTime = 1 / 30

    private let lock = NSLock()
    private var lastCallbackTime: CFAbsoluteTime = 0
    private var healthCheck: Timer?
    private let maxCallbackGap: CFAbsoluteTime = 1.0
    private var restarts = 0
    /// Health checks in a row with audio flowing, after a restart.
    private var healthyTicks = 0
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    /// Bluetooth microphones take a moment to switch profile before they deliver audio.
    private let bluetoothStabilizationDelay: TimeInterval = 0.6

    init(barCount: Int) {
        normalizer = LevelNormalizer(barCount: barCount)
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Start / stop

    func start() throws {
        guard !isRunning else { return }
        normalizer.reset()
        restarts = 0
        let device = Self.preferredInputDevice()
        // Built ahead (prepare()): starting is just starting, about 10 ms instead of ~100.
        if let ready = prepared, ready.device == device {
            prepared = nil
            do {
                try startPrepared(ready)
            } catch {
                AudioUnitUninitialize(ready.unit)
                AudioComponentInstanceDispose(ready.unit)
                try startUnit(device: device)
            }
        } else {
            discardPrepared()
            try startUnit(device: device)
        }
        isRunning = true
        listenForDefaultDeviceChanges()
        startHealthCheck()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        healthCheck?.invalidate()
        healthCheck = nil
        if let fileTimer {
            fileTimer.cancel()
            self.fileTimer = nil
        }
        stopListeningForDeviceChanges()
        stopUnit()
    }

    // MARK: HAL input unit

    // MARK: Ready ahead

    /// A unit built and initialized for the current mic, not started: no audio flows and the mic
    /// indicator stays off until start(). Rebuilt after each recording and when the mic changes.
    private struct Prepared { let unit: AudioUnit; let device: AudioDeviceID; let format: AVAudioFormat; let rate: Double; let frames: UInt32 }
    private var prepared: Prepared?

    /// Builds the next recording's unit now, so the key press only has to start it.
    func prepare() {
        guard !isRunning, prepared == nil else { return }
        let device = Self.preferredInputDevice()
        guard device != kAudioObjectUnknown, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        prepared = try? buildUnit(device: device)
    }

    private func discardPrepared() {
        guard let ready = prepared else { return }
        prepared = nil
        AudioUnitUninitialize(ready.unit)
        AudioComponentInstanceDispose(ready.unit)
    }

    private func startPrepared(_ ready: Prepared) throws {
        renderBuffer = AVAudioPCMBuffer(pcmFormat: ready.format, frameCapacity: max(ready.frames, 4096))
        try check(AudioOutputUnitStart(ready.unit), "start")
        unit = ready.unit
        deviceID = ready.device
        deviceName = Self.name(of: ready.device)
        lock.withLock { lastCallbackTime = CFAbsoluteTimeGetCurrent() }
        DebugLog.write("capture: \(deviceName) at \(Int(ready.rate)) Hz (ready ahead)")
    }

    /// Everything but starting: the unit for `device`, initialized.
    private func buildUnit(device: AudioDeviceID) throws -> Prepared {
        guard device != kAudioObjectUnknown else { throw CaptureError.noInputDevice }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw CaptureError.noHALUnit }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "instance")
        guard let unit = newUnit else { throw CaptureError.noHALUnit }
        var built = false
        defer { if !built { AudioComponentInstanceDispose(unit) } }
        var on: UInt32 = 1, off: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "disable output")
        var device = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "current device")
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "device format")
        guard hardware.mSampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, channels: 1, interleaved: false)
        else { throw CaptureError.noInputDevice }
        var client = format.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                       &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "client format")
        var maxFrames: UInt32 = 4096
        size = u32
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &size)
        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timeStamp, bus, frames, _ in
            Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")
        try check(AudioUnitInitialize(unit), "initialize")
        built = true
        return Prepared(unit: unit, device: device, format: format, rate: hardware.mSampleRate, frames: maxFrames)
    }

    private func startUnit(device: AudioDeviceID) throws {
        guard device != kAudioObjectUnknown else { throw CaptureError.noInputDevice }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw CaptureError.noHALUnit }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "instance")
        guard let unit = newUnit else { throw CaptureError.noHALUnit }
        // Any step below failing leaves nothing behind.
        var started = false
        defer { if !started { AudioComponentInstanceDispose(unit) } }

        var on: UInt32 = 1, off: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "disable output")
        var device = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "current device")

        // The unit can't resample on the input side, so the client format keeps the device rate.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "device format")
        guard hardware.mSampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, channels: 1, interleaved: false)
        else { throw CaptureError.noInputDevice }
        var client = format.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                       &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "client format")

        var maxFrames: UInt32 = 4096
        size = u32
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &size)
        renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(maxFrames, 4096))

        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timeStamp, bus, frames, _ in
            Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")

        try check(AudioUnitInitialize(unit), "initialize")
        try check(AudioOutputUnitStart(unit), "start")
        started = true
        self.unit = unit
        self.deviceID = device
        deviceName = Self.name(of: device)
        lock.withLock { lastCallbackTime = CFAbsoluteTimeGetCurrent() }
        DebugLog.write("capture: \(deviceName) at \(Int(hardware.mSampleRate)) Hz")
    }

    private func stopUnit() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    /// Audio thread. Renders into the preallocated buffer and hands it on synchronously.
    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, let buffer = renderBuffer, frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        lock.withLock { lastCallbackTime = CFAbsoluteTimeGetCurrent() }
        handle(buffer)
        return noErr
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        onBuffer?(buffer)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelUpdate >= levelInterval, let channel = buffer.floatChannelData?[0] else { return }
        lastLevelUpdate = now
        let levels = normalizer.process(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        DispatchQueue.main.async { self.onLevels?(levels) }
    }

    // MARK: Device changes and health

    /// `counts`: a restart for a device change isn't the mic failing, so it doesn't count toward giving up.
    private func restart(reason: String, device: AudioDeviceID? = nil, counts: Bool = true) {
        guard isRunning, fileTimer == nil else { return }
        if counts { restarts += 1 }
        DebugLog.write("capture: restarting (\(reason))")
        stopUnit()
        do {
            try startUnit(device: device ?? Self.preferredInputDevice())
        } catch {
            DebugLog.write("capture: restart failed: \(error)")
        }
    }

    private func startHealthCheck() {
        healthCheck?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, self.fileTimer == nil else { return }
            let gap = CFAbsoluteTimeGetCurrent() - self.lock.withLock { self.lastCallbackTime }
            guard gap > self.maxCallbackGap else {
                // Audio is flowing again: earlier failures are forgiven, so a long session's
                // occasional hiccups never add up to giving up.
                if self.restarts > 0, gap < 0.3 { self.healthyTicks += 1 } else { self.healthyTicks = 0 }
                if self.healthyTicks >= 20 { self.restarts = 0; self.healthyTicks = 0 }
                return
            }
            self.healthyTicks = 0
            if self.restarts < 4 {
                self.restart(reason: String(format: "no callbacks for %.1fs", gap))
            } else {
                // Still dead after a few tries: say so once, then keep trying now and then
                // (a mic coming back mid-meeting is picked up again).
                if self.restarts == 4 { self.onSilentInput?() }
                self.restarts += 1
                if self.restarts % 20 == 0 { self.restart(reason: "still no audio", counts: false) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheck = timer
    }

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func listenForDefaultDeviceChanges() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // A microphone picked in settings stays in use while it's connected; otherwise the
            // listening follows what preferredInputDevice picks now.
            if Self.chosenInputDevice() != nil { return }
            let device = Self.preferredInputDevice()
            guard self.isRunning, device != self.deviceID else { return }
            let delay = Self.isBluetooth(device) ? self.bluetoothStabilizationDelay : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.restart(reason: "input device changed to \(Self.name(of: device))", device: device, counts: false)
            }
        }
        defaultDeviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInputAddress, .main, block)
    }

    private func stopListeningForDeviceChanges() {
        guard let block = defaultDeviceListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInputAddress, .main, block)
        defaultDeviceListener = nil
    }

    // MARK: Device queries

    struct InputDevice: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// Every device with input channels, for the microphone picker.
    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).compactMap { id in uid(of: id).map { InputDevice(uid: $0, name: name(of: id)) } }
    }

    /// The mic to listen on (Settings → Dictation → Microphone):
    /// - one you picked, while it's connected;
    /// - Smart (the default): the built-in mic while the lid is open, so dictation starts at once and
    ///   headphones keep their music quality; with the lid closed (a monitor), a Bluetooth headset's,
    ///   or the Mac's default input;
    /// - Prefer Bluetooth, Built-in, or the system default, as named.
    /// Opening a Bluetooth mic switches the headset into call mode: the first second or so of
    /// speech is lost while it switches, and music in your headphones drops to phone quality.
    static func preferredInputDevice() -> AudioDeviceID {
        if let chosen = chosenInputDevice() { return chosen }
        let fallback = defaultInputDevice()
        switch AppSettings.shared.microphoneUID {
        case AppSettings.Microphone.system: return fallback
        case AppSettings.Microphone.builtIn: return builtInInputDevice() ?? fallback
        case AppSettings.Microphone.bluetooth: return bluetoothInputDevice() ?? fallback
        default:  // Smart, or a picked mic that isn't connected
            // Lid shut: the built-in mic is cut off in hardware, so a headset's, then any other mic
            // (USB, a monitor's or a webcam's), then the default as a last resort.
            return isLidClosed ? (bluetoothInputDevice() ?? externalInputDevice() ?? fallback) : (builtInInputDevice() ?? fallback)
        }
    }

    /// The MacBook's lid is shut (running on a monitor): its built-in mic is out of reach.
    static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let state = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }

    /// A mic that isn't the Mac's own: the default input when it isn't built in, otherwise the first.
    static func externalInputDevice() -> AudioDeviceID? {
        let fallback = defaultInputDevice()
        let builtIn = builtInInputDevice()
        if fallback != kAudioObjectUnknown, fallback != builtIn { return fallback }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids.first { hasInput($0) && $0 != builtIn }
    }

    /// A Bluetooth headset's mic: the default input when it's one, otherwise the first connected.
    static func bluetoothInputDevice() -> AudioDeviceID? {
        let fallback = defaultInputDevice()
        if isBluetooth(fallback) { return fallback }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids.first { hasInput($0) && isBluetooth($0) }
    }

    static func builtInInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids.first { id in
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            return transport == kAudioDeviceTransportTypeBuiltIn && hasInput(id)
        }
    }

    static func chosenInputDevice() -> AudioDeviceID? {
        let wanted = AppSettings.shared.microphoneUID
        guard !wanted.isEmpty else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids.first { uid(of: $0) == wanted && hasInput($0) }
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func defaultInputDevice() -> AudioDeviceID {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, 0, nil, &size, &device)
        return device
    }

    static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "unknown input" }
        return name.takeRetainedValue() as String
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw CaptureError.audioUnit(step, status) }
    }

    enum CaptureError: Error {
        case noInputDevice, noHALUnit
        case audioUnit(String, OSStatus)
    }

    // MARK: Test source

    /// Debug source (`STARLIGHT_TEST_AUDIO=file.wav`): plays a file through the same path in real
    /// time, then silence, so the whole pipeline can be tested without speaking.
    private var fileTimer: DispatchSourceTimer?

    func startFile(_ url: URL) throws {
        guard !isRunning else { return }
        normalizer.reset()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames: AVAudioFrameCount = 1024
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "notch.testaudio"))
        timer.schedule(deadline: .now(), repeating: Double(frames) / format.sampleRate)
        timer.setEventHandler { [weak self] in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            try? file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0, let channel = buffer.floatChannelData?[0] {  // silence after the file ends
                buffer.frameLength = frames
                channel.update(repeating: 0, count: Int(frames))
            }
            self?.handle(buffer)
        }
        fileTimer = timer
        timer.resume()
        isRunning = true
    }
}
