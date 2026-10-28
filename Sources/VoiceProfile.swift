import AVFoundation
import SwiftUI

/// What your voice sounds like to Starlight: the average voice fingerprint of a few seconds of you
/// reading a sentence (256 numbers from the same model that tells meeting speakers apart). Not a
/// recording: the audio is gone the moment the numbers are made.
///
/// In a meeting it tells you from the people in the room. Everything on your microphone used to
/// count as you; a phrase on it that clearly isn't your voice now counts as theirs, numbered like
/// the other side of a call.
///
/// Kept in `~/Library/Application Support/Starlight/voice.json`; Settings → Notes forgets it.
final class VoiceProfile: ObservableObject {
    static let shared = VoiceProfile()

    @Published private(set) var embedding: [Float]?
    @Published private(set) var learned: Date?

    /// Cosine distance past which a phrase on your mic isn't you. Measured with `--voice-test` on
    /// macOS voices: the learned voice on new sentences, fast or slow, 0.16–0.19; eight other
    /// voices 0.50–0.99 (the closest, a similar accent and pitch, 0.50). 0.45 catches them all and
    /// leaves room for your own voice on another mic or a rough line.
    static let notYou: Float = 0.45

    private struct Stored: Codable { let embedding: [Float]; let learned: Date }

    private static var url: URL {
        NotesStore.folder.deletingLastPathComponent().appendingPathComponent("voice.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            embedding = stored.embedding
            learned = stored.learned
        }
    }

    var isLearned: Bool { embedding != nil }

    func save(_ embedding: [Float]) {
        let stored = Stored(embedding: embedding, learned: Date())
        try? JSONEncoder().encode(stored).write(to: Self.url, options: .atomic)
        DispatchQueue.main.async {
            self.embedding = stored.embedding
            self.learned = stored.learned
        }
    }

    func forget() {
        try? FileManager.default.removeItem(at: Self.url)
        embedding = nil
        learned = nil
    }

    /// How far this fingerprint is from yours (0 the same, 2 opposite); nil before it's learned.
    func distance(_ other: [Float]) -> Float? {
        guard let mine = embedding, mine.count == other.count else { return nil }
        return 1 - Self.cosine(mine, other)
    }

    /// Whether a phrase on your microphone is someone else's: only when it's clearly not you.
    func isSomeoneElse(_ audio: [Float]) async -> Bool {
        guard isLearned, audio.count >= 24_000, let other = await SpeakerIdentifier.shared.embedding(audio),
              let distance = distance(other) else { return false }
        if Dev.env("STARLIGHT_DEBUG_SPEAKERS") != nil {
            DebugLog.write(String(format: "voice: phrase on your mic is %.3f from your voice", distance))
        }
        return distance > Self.notYou
    }

    /// A whole audio file as 16 kHz mono, for tests.
    static func load16k(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        return Resampler16k().convert(buffer)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    static func average(_ embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for e in embeddings where e.count == sum.count {
            let norm = max(e.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-6)
            for i in 0..<sum.count { sum[i] += e[i] / norm }
        }
        let norm = max(sum.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-6)
        return sum.map { $0 / norm }
    }
}

/// Learning your voice: you read a sentence, the words light up as you go, a waveform follows
/// you, and once there's enough of you (about seven seconds of speech) it's done.
@MainActor
final class VoiceEnrollment: ObservableObject {
    enum Phase: Equatable { case ready, preparing, listening, finishing, done, failed(String) }

    @Published private(set) var phase: Phase = VoiceProfile.shared.isLearned ? .done : .ready
    /// 0…1: how much of the speech it needs it has.
    @Published private(set) var progress: Double = 0
    /// The voice's loudness right now, 0…1, smoothed: drives the waveform.
    @Published private(set) var level: Double = 0

    static let sentence = "Hey Starlight, this is my voice. Remember how I sound, so you know it's me in meetings and on calls."
    /// Seconds of speech it takes (pauses don't count).
    private let needed: Double = 7

    private var capture: AudioCapture?
    nonisolated(unsafe) private let resampler = Resampler16k()
    /// The 16 kHz speech heard so far, and how many seconds of it; only touched on `audio`.
    nonisolated(unsafe) private var samples: [Float] = []
    nonisolated(unsafe) private var voiced: Double = 0
    private nonisolated let audio = DispatchQueue(label: "notch.enroll")
    private var quietTimer: Task<Void, Never>?

    /// For the PNG renderer: a panel frozen in one state.
    convenience init(preview phase: Phase, progress: Double, level: Double) {
        self.init()
        self.phase = phase
        self.progress = progress
        self.level = level
    }

    func start() {
        guard phase != .listening, phase != .preparing, phase != .finishing else { return }
        progress = 0
        level = 0
        audio.sync { samples = []; voiced = 0 }
        phase = .preparing
        Task {
            let testFile = Dev.env("STARLIGHT_TEST_VOICE_AUDIO")
            if testFile == nil {
                guard await AudioCapture.requestPermission() else { return fail("Starlight needs the microphone for this") }
            }
            // The voice models download once (about 30 MB); they're loading while you start reading.
            SpeakerIdentifier.shared.prepare()
            let capture = AudioCapture(barCount: 8)
            capture.onBuffer = { [weak self] buffer in self?.heard(buffer) }
            // STARLIGHT_TEST_VOICE_AUDIO=file.wav: a recording instead of the mic, for testing.
            do { if let testFile { try capture.startFile(URL(fileURLWithPath: testFile)) } else { try capture.start() } }
            catch { return fail("The microphone didn't start") }
            self.capture = capture
            phase = .listening
            Haptics.start()
            // Nothing at all for twelve seconds: the mic is probably the wrong one.
            quietTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard let self, self.phase == .listening, self.progress < 0.05 else { return }
                self.stopCapture()
                self.fail("Didn't hear anything. Check your microphone")
            }
        }
    }

    func cancel() {
        stopCapture()
        if phase != .done { phase = VoiceProfile.shared.isLearned ? .done : .ready }
    }

    func again() {
        phase = .ready
        start()
    }

    /// On the audio thread: keep the speech, measure it, move the waveform.
    private nonisolated func heard(_ buffer: AVAudioPCMBuffer) {
        let chunk = resampler.convert(buffer)
        guard !chunk.isEmpty else { return }
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        let seconds = Double(chunk.count) / 16_000
        // Speech, not room noise: about -40 dBFS and up.
        let speaking = rms > 0.01
        let voicedNow = audio.sync { () -> Double in
            if speaking { samples += chunk; voiced += seconds }
            return voiced
        }
        let loud = min(1, Double(rms) * 9)
        Task { @MainActor [weak self] in
            guard let self, self.phase == .listening else { return }
            self.level = self.level * 0.55 + loud * 0.45
            self.progress = min(1, voicedNow / self.needed)
            if voicedNow >= self.needed { self.finish() }
        }
    }

    private func finish() {
        guard phase == .listening else { return }
        stopCapture()
        phase = .finishing
        level = 0
        let speech = audio.sync { samples }
        Task {
            guard await SpeakerIdentifier.shared.waitUntilReady(timeout: 90) else {
                return fail("Couldn't load the voice model. Try again later")
            }
            // Three-second windows, each a fingerprint; their average is your voice.
            let window = 48_000
            var prints: [[Float]] = []
            var start = 0
            while start + window <= speech.count {
                if let e = await SpeakerIdentifier.shared.embedding(Array(speech[start..<(start + window)])) { prints.append(e) }
                start += window
            }
            if prints.isEmpty, let e = await SpeakerIdentifier.shared.embedding(speech) { prints.append(e) }
            guard let voice = VoiceProfile.average(prints) else { return fail("That didn't work. Try once more") }
            VoiceProfile.shared.save(voice)
            DebugLog.write("voice: learned from \(prints.count) windows, \(String(format: "%.1f", Double(speech.count) / 16_000)) s of speech")
            progress = 1
            phase = .done
            Haptics.snap()
        }
    }

    private func fail(_ message: String) {
        stopCapture()
        phase = .failed(message)
        Sounds.error()
    }

    private func stopCapture() {
        quietTimer?.cancel()
        quietTimer = nil
        capture?.stop()
        capture = nil
    }
}

// MARK: - Views

/// The panel: the sentence to read, lighting up word by word, over a waveform that follows you.
struct VoiceEnrollView: View {
    @ObservedObject var enrollment: VoiceEnrollment
    /// Skipping is offered in the welcome tour.
    var onSkip: (() -> Void)? = nil

    private var words: [String] { VoiceEnrollment.sentence.split(separator: " ").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch enrollment.phase {
            case .done:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Starlight knows your voice.").font(.system(size: 26, weight: .semibold))
                    Text("In meetings, it can tell you from the people around you.").font(.system(size: 14)).opacity(0.5)
                }
                .transition(.opacity.combined(with: .offset(y: 6)))
            default:
                sentence
            }
            Spacer(minLength: 0)
            Waveform(level: enrollment.level, active: enrollment.phase == .listening, finishing: enrollment.phase == .finishing)
                .frame(height: 44)
                .opacity(enrollment.phase == .done ? 0 : 1)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: enrollment.phase)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            switch enrollment.phase {
            case .ready:
                Text("Read this out loud").font(.system(size: 15, weight: .semibold)).opacity(0.8)
            case .preparing:
                ShimmerText(text: "Getting the mic ready").font(.system(size: 15, weight: .semibold)).opacity(0.8)
            case .listening:
                LiveDot(color: .white)
                Text("Listening").font(.system(size: 15, weight: .semibold)).opacity(0.8)
            case .finishing:
                ShimmerText(text: "Learning your voice").font(.system(size: 15, weight: .semibold)).opacity(0.8)
            case .done:
                OutcomeBadge(ok: true, size: 22).transition(.scale.combined(with: .opacity))
                Text("Done").font(.system(size: 15, weight: .semibold)).opacity(0.8)
            case .failed(let message):
                OutcomeBadge(ok: false, size: 22)
                Text(message).font(.system(size: 15, weight: .semibold)).opacity(0.8)
            }
            Spacer()
            switch enrollment.phase {
            case .ready:
                if let onSkip { WindowPill(title: "Skip", strong: false, action: onSkip) }
                WindowPill(title: "Start", strong: true) { enrollment.start() }
            case .failed:
                WindowPill(title: "Try again", strong: true) { enrollment.again() }
            case .done:
                WindowPill(title: "Learn again", strong: false) { enrollment.again() }
            case .listening:
                WindowPill(title: "Cancel", strong: false) { enrollment.cancel() }
            default:
                EmptyView()
            }
        }
        .frame(height: 30)
    }

    /// The words light up as the speech it needs comes in, so you can see how far along it is.
    private var sentence: some View {
        let lit = enrollment.phase == .finishing ? words.count : Int((enrollment.progress * Double(words.count)).rounded(.down))
        return WrappingWords(words: words, lit: enrollment.phase == .ready || enrollment.phase == .preparing ? -1 : lit)
            .animation(.easeOut(duration: 0.25), value: lit)
    }
}

/// The sentence, wrapped like a paragraph: read words white, the rest dim.
private struct WrappingWords: View {
    let words: [String]
    /// How many are lit; -1 shows them all as plain text to read.
    let lit: Int

    var body: some View {
        WordWrap(spacing: 7, lineSpacing: 5) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(.system(size: 22, weight: .semibold))
                    .opacity(lit < 0 ? 0.9 : index < lit ? 1 : 0.28)
                    .scaleEffect(index == lit - 1 ? 1.04 : 1, anchor: .bottomLeading)
            }
        }
    }
}

private struct WordWrap: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + lineSpacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + lineSpacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// A waveform of a few soft sine lines that swell with your voice and drift while you talk; a
/// flat breathing line at rest, a travelling ripple while it learns.
struct Waveform: View {
    var level: Double
    var active: Bool
    var finishing: Bool

    var body: some View {
        TimelineView(.animation(paused: !active && !finishing && level < 0.01)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let mid = size.height / 2
                let amp = finishing ? 0.35 + 0.15 * sin(t * 3) : active ? 0.08 + level * 0.92 : 0.05
                // Three lines: different speeds and lengths, the front one brightest.
                let lines: [(freq: Double, speed: Double, scale: Double, alpha: Double, width: CGFloat)] = [
                    (1.6, 2.1, 1.0, 0.95, 2), (2.3, -1.4, 0.65, 0.45, 1.5), (3.1, 2.8, 0.4, 0.25, 1.2)]
                for line in lines {
                    var path = Path()
                    let steps = Int(size.width / 2)
                    for i in 0...steps {
                        let x = Double(i) / Double(steps)
                        // Tapered at both ends (a raised cosine), so it never ends in a hard edge.
                        let envelope = 0.5 - 0.5 * cos(2 * .pi * x)
                        let y = mid + CGFloat(sin(x * .pi * 2 * line.freq + t * line.speed) * envelope * amp * line.scale) * (size.height / 2 - 2)
                        let point = CGPoint(x: x * size.width, y: y)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    ctx.stroke(path, with: .color(.white.opacity(line.alpha)), style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// A capsule button: the one main action in white, the quiet one dim.
struct WindowPill: View {
    let title: String
    var strong: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(strong ? .black : .white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(strong ? Color.white.opacity(hovering ? 1 : 0.92) : Color.white.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
