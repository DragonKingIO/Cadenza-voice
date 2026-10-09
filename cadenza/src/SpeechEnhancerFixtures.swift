import Foundation

/// Constructed signals only.
enum SpeechEnhancerFixtures {
    static func tone(_ hz: Float, seconds: Float, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16000)).map { amplitude * sin(2 * Float.pi * hz * Float($0) / 16000) }
    }
    /// A signal that comes and goes like speech: 1 kHz and 2.5 kHz bursts with pauses.
    static func bursts(seconds: Float, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16000)).map { i in
            let t = Float(i) / 16000, on = Int(t / 0.3) % 2 == 0 ? Float(1) : 0
            return on * amplitude * (0.6 * sin(2 * Float.pi * 1000 * t) + 0.4 * sin(2 * Float.pi * 2500 * t))
        }
    }
    static func noise(count: Int, sigma: Float, seed: UInt64) -> [Float] {
        var state = seed | 1
        func next() -> Float { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return Float(Double(state % 2_000_001) / 1_000_000 - 1) }
        return (0..<count).map { _ in (next() + next() + next() + next()) * 0.866 * sigma }
    }
    static func rms(_ s: ArraySlice<Float>) -> Float { s.isEmpty ? 0 : (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot() }

    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("Enhancer " + name, ok) }
        let sr = 16000

        // Round trip
        let signal = bursts(seconds: 3, amplitude: 0.3)
        let same = SpeechEnhancer.subtract(signal, oversubtraction: 0, floorGain: 1)
        var worst: Float = 0
        for i in 600..<(signal.count - 600) { worst = max(worst, abs(same[i] - signal[i])) }
        c("subtraction with nothing to subtract gives the input back (worst error \(worst))", worst < 0.01)

        // High-pass
        let low = SpeechEnhancer.highPass(tone(20, seconds: 2, amplitude: 0.5)), mid = SpeechEnhancer.highPass(tone(1000, seconds: 2, amplitude: 0.5))
        c("high-pass removes rumble and keeps speech frequencies", rms(low[sr...]) < 0.1 * 0.3536 && rms(mid[sr...]) > 0.95 * 0.3536)

        // Estimated distance between speech and room
        let clean = bursts(seconds: 4, amplitude: 0.3)
        let mild = zip(clean, noise(count: clean.count, sigma: 0.0003, seed: 5)).map { $0 + $1 }
        let noisy = zip(bursts(seconds: 4, amplitude: 0.02), noise(count: clean.count, sigma: 0.012, seed: 6)).map { $0 + $1 }
        c("estimated SNR: clean is high, a noisy room is low", SpeechEnhancer.estimatedSNR(mild) > 30 && SpeechEnhancer.estimatedSNR(noisy) < 12)

        // A clean recording is only high-passed
        c("a clean recording is left alone apart from the high-pass", SpeechEnhancer.enhance(mild).count == mild.count && { let e = SpeechEnhancer.enhance(mild); var d: Float = 0; for i in 2000..<(mild.count - 2000) { d = max(d, abs(e[i] - SpeechEnhancer.highPass(mild)[i])) }; return d < 1e-6 }())

        // A noisy recording: the room gets quieter, the speech stays
        let enhanced = SpeechEnhancer.subtract(noisy)
        let pause = (Int(0.3 * 16000) + 1200)..<(Int(0.6 * 16000) - 1200)     // inside the first silent gap
        let burst = 1200..<(Int(0.3 * 16000) - 1200)                          // inside the first burst
        let before = rms(noisy[pause]), after = rms(enhanced[pause])
        c("noisy: the room noise between words drops by at least 6 dB (\(20 * log10(after / before)) dB)", after < before * 0.5)
        c("noisy: the speech keeps most of its level (\(20 * log10(rms(enhanced[burst]) / rms(noisy[burst]))) dB)", rms(enhanced[burst]) > rms(noisy[burst]) * 0.6)
        c("noisy: the speech stands further above the room afterwards", rms(enhanced[burst]) / max(1e-9, rms(enhanced[pause])) > rms(noisy[burst]) / max(1e-9, rms(noisy[pause])) * 1.5)

        // The edges of a recording must not get spikes
        let steady = noise(count: 16000 * 3, sigma: 0.01, seed: 9)
        let steadyOut = SpeechEnhancer.subtract(steady)
        c("no spike at the start or the end (peak \(steadyOut.map(abs).max() ?? 0) against \(steady.map(abs).max() ?? 0))", (steadyOut.map(abs).max() ?? 0) <= (steady.map(abs).max() ?? 0) * 1.05 && (steadyOut.prefix(400).map(abs).max() ?? 0) < 0.06 && (steadyOut.suffix(400).map(abs).max() ?? 0) < 0.06)
        c("the peak of a noisy recording does not grow", (SpeechEnhancer.subtract(noisy).map(abs).max() ?? 0) <= (noisy.map(abs).max() ?? 0) * 1.05)

        // Speech or only the room (the recording's own meter readings)
        func readings(room: Float, speech: Float? = nil, speechChunks: Int = 0, count: Int = 80) -> [Float] {
            var out = (0..<count).map { room * (1 + 0.15 * sin(Float($0) * 1.7)) }
            if let speech { for i in 0..<speechChunks { out[10 + i] = speech * (1 + 0.3 * sin(Float(i) * 0.9)) } }
            return out
        }
        func accepted(_ levels: [Float]) -> Bool { SpeechPresence.looksLikeSpeech(peak: levels.max() ?? 0, levels: levels) }
        c("presence: loud speech is accepted as before", accepted(readings(room: 0.01, speech: 0.5, speechChunks: 30)))
        c("presence: a whisper far under the old threshold is accepted", accepted(readings(room: 0.005, speech: 0.04, speechChunks: 30)) && (readings(room: 0.005, speech: 0.04, speechChunks: 30).max() ?? 1) < SpeechPresence.loudEnough)
        c("presence: a whisper in a noisier room is accepted", accepted(readings(room: 0.015, speech: 0.08, speechChunks: 30)))
        c("presence: the room alone is dropped, quiet or less quiet", !accepted(readings(room: 0.005)) && !accepted(readings(room: 0.02)) && !accepted(readings(room: 0.15)))
        c("presence: digital silence is dropped", !accepted([Float](repeating: 0, count: 80)) && !accepted([Float](repeating: 0.001, count: 80)))
        c("presence: a cough or a tap is not speech", !accepted(readings(room: 0.005, speech: 0.08, speechChunks: 3)))
        c("presence: too short a recording is dropped unless it is loud", !accepted(Array(readings(room: 0.005, speech: 0.04, speechChunks: 5).prefix(8))) && SpeechPresence.looksLikeSpeech(peak: 0.5, levels: [0.5]))
        c("presence: speech without any pause is not told from the room (as before)", !accepted([Float](repeating: 0.04, count: 80)))

        // Safety
        c("too short, silent or broken input comes back unchanged", SpeechEnhancer.enhance([0.1, 0.2]) == [0.1, 0.2] && SpeechEnhancer.enhance([Float](repeating: 0, count: 8000)).count == 8000 && SpeechEnhancer.enhance([Float](repeating: .nan, count: 8000)).filter { $0.isNaN }.count == 8000)
        c("the output is as long as the input and finite", { let e = SpeechEnhancer.enhance(noisy); return e.count == noisy.count && e.allSatisfy { $0.isFinite } }())
        SpeechEnhancer.enabled = false
        c("switched off it does nothing", SpeechEnhancer.enhance(noisy) == noisy)
        SpeechEnhancer.enabled = true
    }
}
