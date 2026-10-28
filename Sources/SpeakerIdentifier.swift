import FluidAudio
import Foundation

/// Tells the other people in a meeting apart: each of their phrases gets a voice fingerprint
/// (a 256-number speaker embedding from FluidAudio's pyannote/WeSpeaker models on the Neural
/// Engine), and an online clusterer either matches it to someone already heard or starts a new
/// speaker. Speakers are numbered in the order they first speak: "1", "2", …
///
/// Runs off the main thread. The models download once (about 30 MB), in the background after
/// the voice model, so they're there by the first meeting; until they're ready, lines stay
/// plain "Them".
final class SpeakerIdentifier: @unchecked Sendable {
    static let shared = SpeakerIdentifier()

    private let queue = DispatchQueue(label: "notch.speakers", qos: .userInitiated)
    private var manager: DiarizerManager?
    private var loading = false
    private var numbering: [String: String] = [:]

    /// Cosine distance under which two phrases count as the same voice. Measured on two macOS
    /// voices: the same voice came in at 0.15–0.17, a different one at 0.77–0.79; FluidAudio's
    /// default (0.84) merged them. 0.55 sits between, with room for call-quality audio.
    static let sameVoice: Float = 0.55

    private static func freshManager() -> SpeakerManager {
        SpeakerManager(speakerThreshold: sameVoice, embeddingThreshold: 0.4, minSpeechDuration: 1.0, minEmbeddingUpdateDuration: 2.0)
    }

    /// Downloads the models ahead of the first meeting, without keeping them in memory. Once.
    static func fetchModels() {
        guard !fetched else { return }
        fetched = true
        guard !FileManager.default.fileExists(atPath: DiarizerModels.defaultModelsDirectory().path) else { return }
        Task.detached(priority: .background) {
            do {
                _ = try await DiarizerModels.downloadIfNeeded()
                DebugLog.write("speakers: models downloaded")
            } catch {
                DebugLog.write("speakers: models didn't download: \(error.localizedDescription)")
            }
        }
    }
    private nonisolated(unsafe) static var fetched = false

    /// Load the models (download the first time). Safe to call repeatedly.
    func prepare() {
        queue.async { [self] in
            guard manager == nil, !loading else { return }
            loading = true
            Task.detached(priority: .utility) { [self] in
                do {
                    let models = try await DiarizerModels.downloadIfNeeded()
                    let diarizer = DiarizerManager(config: .default)
                    diarizer.initialize(models: models)
                    diarizer.speakerManager = Self.freshManager()
                    queue.async { self.manager = diarizer; self.loading = false }
                    DebugLog.write("speakers: models ready")
                } catch {
                    queue.async { self.loading = false }
                    DebugLog.write("speakers: models failed to load: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Whether the voice models are loaded.
    var isReady: Bool { queue.sync { manager != nil } }

    /// Loads the models if needed and waits for them, up to `timeout` seconds. False if they
    /// didn't come (no connection the first time, say).
    func waitUntilReady(timeout: TimeInterval = 60) async -> Bool {
        prepare()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReady { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return isReady
    }

    /// The voice fingerprint of some 16 kHz mono speech, without assigning it to anyone.
    func embedding(_ audio: [Float]) async -> [Float]? {
        guard audio.count >= 16_000 else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let manager else { return continuation.resume(returning: nil) }
                continuation.resume(returning: try? manager.extractSpeakerEmbedding(from: audio))
            }
        }
    }

    /// A new meeting: forget everyone from the last one.
    func reset() {
        queue.async { [self] in
            numbering = [:]
            pending = []
            manager?.speakerManager = Self.freshManager()
        }
    }

    /// Who said this phrase (16 kHz mono): "1", "2", …, or nil if it's too short to tell or the
    /// models aren't ready yet.
    ///
    /// One person must not become several. Voices drift (laughing, emphasis, a bad line, two
    /// brothers who sound alike), so:
    /// - a phrase joins the closest speaker when it's within `sameVoice` (and refines their voice);
    /// - one that's further but not clearly someone else (under `newVoice`), or too short to be
    ///   sure (under `newSpeakerSeconds`), joins the closest speaker without changing their voice;
    /// - only a long phrase clearly unlike everyone starts a new speaker;
    /// - speakers whose voices have come together are merged (`onMerge` relabels their lines).
    func identify(_ audio: [Float], at time: TimeInterval = 0) async -> String? {
        guard audio.count >= 16_000 else { return nil }  // under a second: not enough voice
        let seconds = Float(audio.count) / 16_000
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let manager else { return continuation.resume(returning: nil) }
                do {
                    let embedding = try manager.extractSpeakerEmbedding(from: audio)
                    let closest = manager.speakerManager.findSpeaker(with: embedding, speakerThreshold: 2)
                    if Dev.env("STARLIGHT_DEBUG_SPEAKERS") != nil {
                        let all = manager.speakerManager.findMatchingSpeakers(with: embedding, speakerThreshold: 2)
                            .map { String(format: "%@ %.3f", numbering[$0.id] ?? $0.id, $0.distance) }.joined(separator: ", ")
                        DebugLog.write("speakers: \(String(format: "%.1f", seconds))s phrase, distances: \(all)")
                    }
                    var id: String?
                    var promoted: [TimeInterval] = []
                    pending.removeAll { Date().timeIntervalSince($0.heard) > 300 }
                    if let near = closest.id, closest.distance >= Self.sameVoice,
                       closest.distance < Self.newVoice || seconds < Self.newSpeakerSeconds {
                        id = near  // probably them, not sure enough to learn from it
                    } else if let near = closest.id, closest.distance >= Self.sameVoice {
                        // Clearly unlike everyone: a new speaker only once a second phrase agrees.
                        if let match = pending.firstIndex(where: { 1 - VoiceProfile.cosine($0.embedding, embedding) < Self.sameVoice }) {
                            id = manager.speakerManager.assignSpeaker(embedding, speechDuration: seconds)?.id
                            promoted = [pending[match].time]
                            pending.remove(at: match)
                        } else {
                            pending.append((embedding, time, Date()))
                            id = near
                        }
                    } else {
                        id = manager.speakerManager.assignSpeaker(embedding, speechDuration: seconds)?.id
                    }
                    guard let id else { return continuation.resume(returning: nil) }
                    if numbering[id] == nil { numbering[id] = String(numbering.values.compactMap(Int.init).max().map { $0 + 1 } ?? 1) }
                    let label = numbering[id]
                    // The candidate's first phrase was filed with someone else: it's theirs now.
                    if let newLabel = numbering[id] {
                        for earlier in promoted { DispatchQueue.main.async { self.onRelabel?(earlier, newLabel) } }
                    }
                    mergeClose(manager)
                    continuation.resume(returning: numbering[id] ?? label)
                } catch {
                    DebugLog.write("speakers: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Phrases clearly unlike everyone, waiting for a second that agrees before they're someone new.
    private var pending: [(embedding: [Float], time: TimeInterval, heard: Date)] = []

    /// Called on the main thread when an earlier phrase (by its time) turns out to be a new speaker's.
    var onRelabel: ((_ time: TimeInterval, _ label: String) -> Void)?

    /// Called on the main thread when two speakers turn out to be one: every "from" becomes "into".
    var onMerge: ((_ from: String, _ into: String) -> Void)?

    /// Speakers whose voices have drifted together, merged into the one heard first.
    private func mergeClose(_ manager: DiarizerManager) {
        for pair in manager.speakerManager.findMergeablePairs(speakerThreshold: Self.mergeVoices) {
            guard let from = numbering[pair.speakerToMerge], let into = numbering[pair.destination] else { continue }
            // Keep the earlier number: "Speaker 7" folds into "Speaker 3", not the other way.
            let (source, destination) = (Int(from) ?? 0) > (Int(into) ?? 0) ? (pair.speakerToMerge, pair.destination) : (pair.destination, pair.speakerToMerge)
            guard let sourceLabel = numbering[source], let destinationLabel = numbering[destination], sourceLabel != destinationLabel else { continue }
            manager.speakerManager.mergeSpeaker(source, into: destination)
            for (key, value) in numbering where value == sourceLabel { numbering[key] = destinationLabel }
            DebugLog.write("speakers: merged speaker \(sourceLabel) into \(destinationLabel)")
            DispatchQueue.main.async { self.onMerge?(sourceLabel, destinationLabel) }
        }
    }

    /// Over this, a long enough phrase is a candidate new speaker (made one when a second agrees).
    /// Measured with `--speakers-test` on macOS voices: one voice at other speeds and pitches
    /// 0.12–0.36 from itself; the two closest different voices 0.62–0.63 from their nearest.
    static let newVoice: Float = 0.5
    /// Shorter phrases never start a new speaker: too little voice to be sure.
    static let newSpeakerSeconds: Float = 2.5
    /// Two speakers this close are the same person.
    static let mergeVoices: Float = 0.40
}
