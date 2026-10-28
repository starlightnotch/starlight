import Foundation

/// Turns microphone buffers into bar levels (0–100) that look like your voice: loud when you
/// talk, still when you don't, the same at a whisper or a shout.
///
/// 1. Loudness on a decibel scale (how ears hear it), measured against a noise floor that
///    follows the room: it sinks quickly to quiet moments and rises slowly, so a fan or hum
///    reads as silence.
/// 2. An envelope over that: it jumps up when you start talking and drains away when you stop.
/// 3. Each bar takes the peak of its own slice of the buffer, relative to the buffer's loudest
///    slice, scaled by the envelope. Speech spreads across the bars instead of moving them all at once.
final class LevelNormalizer {
    let barCount: Int
    /// Loudness that counts as "talking" above the room's floor, and full scale.
    private let speechAboveFloor: Float = 6     // dB
    private let fullScaleAboveFloor: Float = 34 // dB
    /// Per buffer (about 85 per second): how fast the envelope rises and falls.
    private let rise: Float = 0.55
    private let fall: Float = 0.1
    /// The noise floor drops a quarter of the way to a quieter moment each buffer, and creeps up
    /// at most this many dB per buffer (under 2 dB a second), so talking never becomes "the room".
    private let floorDown: Float = 0.25
    private let floorUpLimit: Float = 0.02

    private var floor: Float = -60
    private var envelope: Float = 0
    private let lock = NSLock()

    init(barCount: Int) { self.barCount = barCount }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        envelope = 0
        floor = -60
    }

    func process(_ samples: UnsafeBufferPointer<Float>) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        let n = samples.count
        guard n > 1 else { return Array(repeating: 0, count: barCount) }

        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        let db = 10 * log10(max(sumSquares / Float(n), 1e-10))

        // The floor follows the quietest recent sound.
        floor += db < floor ? floorDown * (db - floor) : min(floorUpLimit, db - floor)
        floor = min(max(floor, -80), -20)
        let above = db - floor
        let target = above < speechAboveFloor ? 0 : min((above - speechAboveFloor) / (fullScaleAboveFloor - speechAboveFloor), 1)
        envelope += (target > envelope ? rise : fall) * (target - envelope)

        // The shape across the bars: each slice's peak against the loudest slice.
        let slice = max(n / barCount, 1)
        var peaks = [Float](repeating: 0, count: barCount)
        for i in 0..<barCount {
            let start = i * slice, end = min(start + slice, n)
            guard start < end else { continue }
            var peak: Float = 0
            for j in start..<end { peak = max(peak, abs(samples[j])) }
            peaks[i] = peak
        }
        let loudest = max(peaks.max() ?? 0, 1e-6)
        return peaks.map { Int(min((0.35 + 0.65 * $0 / loudest) * envelope, 1) * 100) }
    }
}
