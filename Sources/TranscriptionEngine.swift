import AVFoundation
import FluidAudio

/// The swappable voice engine. Audio arrives as microphone buffers while recording;
/// `finish()` returns the final text. Live text is reported through `onPartial`.
protocol TranscriptionEngine: AnyObject {
    var displayName: String { get }
    /// Model download/load progress, for the notch to show.
    var statusHandler: ((EngineStatus) -> Void)? { get set }
    /// Starts loading in the background; never blocks recording.
    func prepare()
    func start(onPartial: @escaping (String) -> Void)
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel()
}

enum EngineStatus: Equatable {
    case idle
    case loading(String, Double?)
    case ready
    case failed(String)
}

/// One Parakeet TDT model (FluidAudio, Neural Engine) shared by dictation and meeting notes:
/// v2 for English, or v3 for 25 European languages (Settings → Dictation → Languages). It loads at
/// launch and stays loaded, or, with "Unload voice model when not in use" on, unloads after 30
/// idle minutes and loads again on the next use.
final class ParakeetModel {
    static let shared = ParakeetModel()
    static var version: AsrModelVersion { AppSettings.shared.speechLanguages == .european ? .v3 : .v2 }
    /// The download, as said in the notch while it installs (measured on disk, rounded).
    static var downloadSize: String { version == .v3 ? "460 MB" : "440 MB" }
    /// The model is on this Mac already (it only has to load), or still has to download.
    static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }
    /// The status label while the files come down. FluidAudio's fraction runs 0…0.5 for the
    /// download and 0.5…1 for preparing it for this Mac.
    static let downloadingLabel = "Downloading voice model"
    static let sampleRate = 16_000
    /// FluidAudio needs at least 1s; shorter clips are padded with silence.
    static let minimumSamples = 16_000

    var statusHandler: ((EngineStatus) -> Void)?

    private let lock = NSLock()
    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    private var users = 0
    /// Unload after 30 idle minutes: loading again costs a second or two on the next dictation.
    /// STARLIGHT_VOICE_IDLE=<seconds> shortens it for testing.
    private let idleUnload: TimeInterval = Dev.env("STARLIGHT_VOICE_IDLE").flatMap(TimeInterval.init) ?? 1800
    private var unloadWork: DispatchWorkItem?
    /// When the last use ended (main thread), so turning the setting on counts the idle time so far.
    private var lastUse = Date()

    var isLoaded: Bool { lock.withLock { manager != nil } }

    /// Starts loading in the background if it isn't loaded.
    func prepare() { _ = loading() }

    /// The load, started if needed, taken under one lock: a failed load or an idle unload
    /// clearing it in between can't leave the caller with nothing.
    private func loading() -> Task<AsrManager, Error> {
        lock.lock(); defer { lock.unlock() }
        if let loadTask { return loadTask }
        let task = Task { [weak self] () throws -> AsrManager in
            do {
                self?.report(.loading("Getting voice model", nil))
                let models = try await AsrModels.downloadAndLoad(version: Self.version) { progress in
                    let label: String = switch progress.phase {
                    case .listing: "Getting voice model"
                    case .downloading: Self.downloadingLabel
                    case .compiling: "Preparing voice model"
                    }
                    self?.report(.loading(label, progress.fractionCompleted))
                }
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                // One throwaway pass: the Neural Engine's first run is slow (about 2 s), so it's
                // spent here rather than on your first phrase.
                let warm = Date()
                _ = try? await Self.transcribe([Float](repeating: 0, count: 16_000), with: manager)
                DebugLog.write(String(format: "parakeet: warmed up in %.2fs", Date().timeIntervalSince(warm)))
                self?.lock.withLock { self?.manager = manager }
                self?.report(.ready)
                DispatchQueue.main.async {
                    guard let self, self.users == 0 else { return }
                    self.lastUse = Date()  // idle from now, not from before a reload
                    self.scheduleUnload()
                }
                return manager
            } catch {
                self?.lock.withLock { self?.loadTask = nil }
                self?.report(.failed("Voice model failed to load"))
                throw error
            }
        }
        loadTask = task
        return task
    }

    /// The languages setting changed: let the loaded model go and load the other one (it
    /// downloads the first time).
    func reload() {
        let old: AsrManager? = lock.withLock {
            let current = manager
            manager = nil
            loadTask = nil
            return current
        }
        if let old { Task { await old.cleanup() } }
        DebugLog.write("parakeet: switching to \(Self.version)")
        prepare()
    }

    /// Keeps the model loaded until the matching `endUse()`.
    func beginUse() {
        DispatchQueue.main.async { [self] in
            unloadWork?.cancel()
            users += 1
        }
        prepare()
    }

    func endUse() {
        DispatchQueue.main.async { [self] in
            users = max(users - 1, 0)
            guard users == 0 else { return }
            lastUse = Date()
            scheduleUnload()
        }
    }

    /// Settings → Dictation → "Unload voice model when not in use" changed (main thread). On: it
    /// goes once it has been idle 30 minutes, counting from the last use (at once if that's
    /// longer ago). Off: it loads now and stays.
    func unloadSettingChanged() {
        if AppSettings.shared.unloadVoiceModel {
            scheduleUnload()
        } else {
            unloadWork?.cancel()
            unloadWork = nil
            prepare()
        }
    }

    /// Lets the model go after 30 idle minutes (main thread), only with the unload setting on.
    /// Also after the load at launch, so it isn't held all day for someone who doesn't dictate.
    private func scheduleUnload() {
        unloadWork?.cancel()
        unloadWork = nil
        guard AppSettings.shared.unloadVoiceModel else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.users == 0, AppSettings.shared.unloadVoiceModel, let manager = self.lock.withLock({ self.manager }) else { return }
            self.lock.withLock { self.manager = nil; self.loadTask = nil }
            Task { await manager.cleanup() }
            self.report(.idle)
            DebugLog.write("parakeet: unloaded after idle")
        }
        unloadWork = work
        let wait = max(idleUnload - Date().timeIntervalSince(lastUse), 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Transcribes 16 kHz mono samples, waiting for the model if it is still loading.
    func transcribe(_ audio: [Float]) async throws -> String {
        let manager = try await loading().value
        return try await Self.transcribe(audio, with: manager)
    }

    /// Transcribes only if the model is already loaded (live previews never wait for it).
    func transcribeIfLoaded(_ audio: [Float]) async throws -> String? {
        guard let manager = lock.withLock({ manager }) else { return nil }
        return try await Self.transcribe(audio, with: manager)
    }

    private static func transcribe(_ audio: [Float], with manager: AsrManager) async throws -> String {
        var padded = audio
        if padded.count < minimumSamples { padded += [Float](repeating: 0, count: minimumSamples - padded.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(padded, decoderState: &state).text
    }

    private func report(_ status: EngineStatus) {
        DispatchQueue.main.async { self.statusHandler?(status) }
    }
}

/// Converts any capture format to 16 kHz mono Float32 for Parakeet. One long-lived converter per
/// stream so the filter state carries across buffers (no clicks at buffer edges).
final class Resampler16k {
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func reset() { converter = nil }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return [] }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}

/// Dictation on Parakeet.
///
/// Audio is buffered from the first moment of recording, even before the model has finished
/// downloading, so nothing you say is lost. While you talk, the recording so far is transcribed
/// again every ~0.7s for live text (Parakeet runs ~100× real time). When you stop, one final pass
/// over the whole clip gives the result.
final class ParakeetEngine: TranscriptionEngine {
    let displayName = "Parakeet v2"
    var statusHandler: ((EngineStatus) -> Void)? {
        get { model.statusHandler }
        set { model.statusHandler = newValue }
    }

    private let model = ParakeetModel.shared
    private let lock = NSLock()
    private var samples: [Float] = []
    private let resampler = Resampler16k()
    private var previewTask: Task<Void, Never>?
    private var onPartial: ((String) -> Void)?
    private var inUse = false

    private let previewInterval: UInt64 = 700_000_000
    /// How much audio there was at the last live-text pass.
    private var lastPreviewTotal = 0
    private let previewWindowSamples = 16_000 * 25  // live text covers the last 25s

    func prepare() { model.prepare() }

    func start(onPartial: @escaping (String) -> Void) {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            resampler.reset()
        }
        lastPreviewTotal = 0
        if !inUse { inUse = true; model.beginUse() }
        self.onPartial = onPartial
        previewTask?.cancel()
        previewTask = Task { [weak self] in await self?.previewLoop() }
    }

    /// Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { samples.append(contentsOf: resampler.convert(buffer)) }
    }

    private func snapshot(last count: Int? = nil) -> [Float] {
        lock.withLock {
            guard let count, samples.count > count else { return samples }
            return Array(samples.suffix(count))
        }
    }

    private func previewLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: previewInterval)
            guard !Task.isCancelled else { return }
            let audio = snapshot(last: previewWindowSamples)
            guard audio.count >= ParakeetModel.minimumSamples / 2 else { continue }
            // Nothing new but quiet since the last pass (a pause): the live text can't have changed.
            let total = lock.withLock { samples.count }
            let fresh = min(total - lastPreviewTotal, audio.count)
            if fresh > 0, lastPreviewTotal > 0 {
                let tail = audio.suffix(fresh)
                let rms = (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
                if rms < 0.004 { lastPreviewTotal = total; continue }
            }
            lastPreviewTotal = total
            // Still loading: keep buffering, live text starts once the model is ready.
            if let text = try? await model.transcribeIfLoaded(audio), !Task.isCancelled {
                let onPartial = self.onPartial
                DispatchQueue.main.async { onPartial?(text) }
            }
        }
    }

    private func release() {
        if inUse { inUse = false; model.endUse() }
    }

    func finish() async throws -> String {
        defer { release() }
        previewTask?.cancel()
        await previewTask?.value
        previewTask = nil
        let audio = snapshot()
        DebugLog.write(String(format: "parakeet: %.1fs of audio", Double(audio.count) / 16_000))
        guard audio.count >= ParakeetModel.minimumSamples / 4 else { return "" }  // under 0.25s: nothing said
        return try await model.transcribe(audio)
    }

    func cancel() {
        release()
        previewTask?.cancel()
        previewTask = nil
        lock.withLock { samples.removeAll() }
    }
}
