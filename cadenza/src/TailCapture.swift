import Foundation

/// How long capture continues after the key is released, and whether remote holds use the tail rescue.
/// Keyboard: a fixed 300 ms (0 restores the old behaviour).
/// Remote: every hold uses the tail rescue. `remoteTailRescueEnabled = false` is the rollback: the Mac microphone stays closed
/// and the recording ends at AUDIO_STOP, as before.
enum TailPolicy {
    static let keyboardProductionExtraMs = 300
    static let remoteTailRescueEnabled = true
    static let remoteExtraMs = 300
    /// Above this many BLE packets (21 s) AUDIO_STOP is the firmware's stream limit, not the key: the recording ends as before.
    static let firmwareLimitPackets = 1400
}

/// Remote tail rescue. After AUDIO_STOP the remote sends nothing, and the Mac microphone used to start only then (about 190-390 ms
/// before its first sample), so the last stretch of a fast sentence was lost. Here the Mac microphone runs from the start of the hold
/// into this ring, nothing of it reaches recognition, and at AUDIO_STOP the part after the last BLE packet is spliced in and
/// later samples follow live. Without AUDIO_STOP the ring is simply dropped.
///
/// Alignment: both streams are stamped on arrival. Their delays differ (BLE connection interval and stack against the audio buffer),
/// so at the splice the lag between the two loudness envelopes of the same speech is measured (bounded, and only trusted when the
/// two envelopes agree) and the cut is placed on the microphone's own time line. The cut is a sample index, so a chunk is trimmed
/// inside, and a cut that lies after the newest chunk waits for the next one. The last 10 ms of BLE audio are held back and
/// cross-faded with the microphone over the same 10 ms, so there is no jump at the seam.
///
/// Level: the microphone is scaled to the BLE level by the median ratio of the two envelopes over 160 ms windows that hold speech
/// in both, bounded; with too little speech to measure the gain is 1.
final class TailSplicer {
    static let rate = 16000.0
    static let minGain: Float = 0.2, maxGain: Float = 4
    static let crossfade = 160                   // 10 ms
    static let maxLagMs = 100                    // the lag is searched in -maxLag...+2*maxLag
    static let minCorrelation = 0.6
    var maxRingSamples = 48000                   // 3 s: AUDIO_STOP follows the last BLE packet within about 35 ms

    private var ring: [Int16] = []
    private var base = 0                         // absolute index of ring[0]
    private var chunks: [(end: Int, arrival: Double)] = []
    private var total = 0
    private var held: [Int16] = []               // newest BLE samples not yet sent on
    private var bleEnv: [Int: (e: Double, n: Int)] = [:], macEnv: [Int: (e: Double, n: Int)] = [:]   // 10 ms buckets on the arrival clock

    private(set) var live = false
    private(set) var gain: Float = 1
    private(set) var rawRatio: Float?            // measured BLE/mic ratio before the bounds
    private(set) var lagMs = 0                   // BLE arrival clock minus mic arrival clock for the same sound
    private(set) var correlation: Double?
    private(set) var outputSamples = 0           // mic samples sent on (crossfade included)
    private(set) var cutIndex = 0
    private var startAbs = 0                     // first mic sample of the cross-fade
    private var mixed = 0                        // held samples already blended
    var hasMic: Bool { total > 0 }

    // MARK: BLE side

    /// BLE audio goes through here: everything except the newest 10 ms is returned to be sent on now.
    func pushBLE(_ pcm: [Int16], arrival: Double) -> [Int16] {
        guard !live else { return [] }
        Self.accumulate(pcm, arrival: arrival, into: &bleEnv)
        held.append(contentsOf: pcm)
        guard held.count > Self.crossfade else { return [] }
        let out = Array(held[..<(held.count - Self.crossfade)])
        held.removeFirst(held.count - Self.crossfade)
        return out
    }

    /// Without a splice the held BLE samples are sent on unchanged (stop, cancel of the ring, firmware limit); after a splice, only what was not blended.
    func finish() -> [Int16] {
        let rest: [Int16]
        if live { rest = mixed < held.count ? Array(held[mixed...]) : [] } else { rest = held }
        held = []; mixed = 0
        return rest
    }

    // MARK: Microphone side

    /// Returns nil while only buffering, the samples to send on once the splice happened (possibly empty).
    func appendMic(_ pcm: [Int16], arrival: Double) -> [Int16]? {
        guard !pcm.isEmpty else { return live ? [] : nil }
        let first = total
        total += pcm.count
        chunks.append((total, arrival))
        Self.accumulate(pcm, arrival: arrival, into: &macEnv)
        if live { return emit(pcm, from: first) }
        ring.append(contentsOf: pcm)
        if ring.count > maxRingSamples {
            let drop = ring.count - maxRingSamples
            ring.removeFirst(drop); base += drop
            chunks.removeAll { $0.end <= base }
        }
        return nil
    }

    /// Absolute sample index at a time on the mic's arrival clock. A time after the newest chunk is extrapolated at 16 kHz so that a chunk
    /// that has not arrived yet can still be trimmed when it does.
    func index(at t: Double) -> Int {
        var prev = base
        for c in chunks {
            let n = c.end - prev, t0 = c.arrival - Double(n) / Self.rate
            if t <= t0 { return prev }
            if t < c.arrival { return prev + Int(((t - t0) * Self.rate).rounded()) }
            prev = c.end
        }
        guard let last = chunks.last else { return total }
        return total + Int(((t - last.arrival) * Self.rate).rounded())
    }

    /// AUDIO_STOP. Sends on the blended BLE tail and the microphone audio that is already there; the rest follows from `appendMic`.
    func splice(lastBLEArrival: Double) -> [Int16] {
        guard !live else { return [] }
        measure()
        let cutTime = lastBLEArrival - Double(lagMs) / 1000
        cutIndex = max(index(at: cutTime), base)
        let xf = held.count
        var out: [Int16] = []
        startAbs = cutIndex - xf
        if startAbs < base {                     // the ring does not reach back far enough: send that part of the BLE tail as it is
            let lead = min(xf, base - startAbs)
            out.append(contentsOf: held[..<lead]); mixedLead(lead); startAbs = base
        }
        live = true
        if total > base { out.append(contentsOf: emit(ring, from: base)) }
        ring = []
        return out
    }

    private func mixedLead(_ lead: Int) { held.removeFirst(lead) }

    private func emit(_ pcm: [Int16], from first: Int) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(pcm.count)
        let xf = held.count
        for (j, s) in pcm.enumerated() {
            let i = first + j
            if i < startAbs { continue }
            let k = i - startAbs
            let m = Float(s) * gain
            if k < xf {
                let w = (Float(k) + 0.5) / Float(xf)
                out.append(Self.clip(Float(held[k]) * (1 - w) + m * w)); mixed = max(mixed, k + 1)
            } else { out.append(Self.clip(m)) }
        }
        outputSamples += out.count
        return out
    }

    // MARK: Measuring lag and level

    private static func accumulate(_ pcm: [Int16], arrival: Double, into env: inout [Int: (e: Double, n: Int)]) {
        let n = pcm.count
        var bucket = Int.min, e = 0.0, cnt = 0
        for (j, s) in pcm.enumerated() {
            let b = Int(((arrival - Double(n - 1 - j) / rate) * 100).rounded(.down))
            if b != bucket {
                if cnt > 0 { var cell = env[bucket] ?? (0, 0); cell.e += e; cell.n += cnt; env[bucket] = cell }
                bucket = b; e = 0; cnt = 0
            }
            e += Double(s) * Double(s); cnt += 1
        }
        if cnt > 0 { var cell = env[bucket] ?? (0, 0); cell.e += e; cell.n += cnt; env[bucket] = cell }
        if env.count > 1500, let newest = env.keys.max() { env = env.filter { $0.key > newest - 1200 } }
    }

    private static func rms(_ c: (e: Double, n: Int)?) -> Double? { c.flatMap { $0.n >= 80 ? ($0.e / Double($0.n)).squareRoot() : nil } }

    /// Lag from the envelope correlation, then the median level ratio over aligned 160 ms windows.
    func measure() {
        lagMs = 0; correlation = nil; rawRatio = nil; gain = 1
        guard let lo = macEnv.keys.min(), let hi = macEnv.keys.max() else { return }
        func corr(lag: Int) -> (Double, Int) {
            var xs: [Double] = [], ys: [Double] = []
            for b in lo...hi {
                if let m = Self.rms(macEnv[b]), let e = Self.rms(bleEnv[b + lag]) { xs.append(m); ys.append(e) }
            }
            guard xs.count >= 50 else { return (-1, xs.count) }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for i in xs.indices { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx); syy += (ys[i] - my) * (ys[i] - my) }
            return sxx > 0 && syy > 0 ? (sxy / (sxx * syy).squareRoot(), xs.count) : (-1, xs.count)
        }
        var best = (lag: 0, c: -1.0)
        for lag in (-Self.maxLagMs / 10)...(2 * Self.maxLagMs / 10) {
            let c = corr(lag: lag).0
            if c > best.c { best = (lag, c) }
        }
        correlation = best.c
        let edge = best.lag == -Self.maxLagMs / 10 || best.lag == 2 * Self.maxLagMs / 10
        let lag = best.c >= Self.minCorrelation && !edge ? best.lag : 0
        lagMs = lag * 10
        var ratios: [Double] = []
        var w = lo
        while w + 16 <= hi {
            var me = 0.0, mn = 0, be = 0.0, bn = 0
            for b in w..<(w + 16) {
                if let c = macEnv[b] { me += c.e; mn += c.n }
                if let c = bleEnv[b + lag] { be += c.e; bn += c.n }
            }
            if mn >= 1600, bn >= 1600 {
                let mr = (me / Double(mn)).squareRoot(), br = (be / Double(bn)).squareRoot()
                if mr >= 40, br >= 40 { ratios.append(br / mr) }
            }
            w += 16
        }
        guard ratios.count >= 4 else { return }
        ratios.sort()
        let r = Float(ratios[ratios.count / 2])
        rawRatio = r
        gain = min(Self.maxGain, max(Self.minGain, r))
    }

    static func clip(_ v: Float) -> Int16 { Int16(max(-32768, min(32767, v.rounded()))) }
    static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in (0..<data.count / 2).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
    }
    static func data(_ pcm: [Int16]) -> Data {
        var d = Data(capacity: pcm.count * 2)
        for s in pcm { var v = s.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        return d
    }
}

enum TailSpliceFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ n: String, _ ok: Bool) { check("tail splice: " + n, ok) }
        let rate = 16000.0
        /// Speech-like signal: bursts of 0.2 rad/sample tone with a slow envelope, so envelopes correlate and have a clear lag.
        func sig(_ i: Int) -> Double { let env = max(0, sin(Double(i) / rate * 2 * .pi * 1.7)); return env * sin(Double(i) * 0.2) }
        func samples(_ range: Range<Int>, amp: Double, shift: Int = 0) -> [Int16] { range.map { Int16(amp * sig($0 - shift)) } }
        let mac0 = 100.0       // mic clock origin; sample i arrives at mac0 + i/rate (chunk end)
        /// Feeds BLE packets (240 samples, delayed by `lagMs` on the arrival clock) and mic chunks of `chunk` samples for `seconds`.
        func session(seconds: Double, bleAmp: Double, macAmp: Double, lagMs: Int, chunk: Int = 1360, micUntil: Int? = nil) -> (s: TailSplicer, sent: [Int16], micEnd: Int, bleEnd: Int) {
            let s = TailSplicer(); var sent: [Int16] = []
            let n = Int(seconds * rate); let bleN = (n / 240) * 240
            var m = 0
            var b = 0
            while b < bleN || m < (micUntil ?? n) {
                let tb = b < bleN ? mac0 + Double(b + 240) / rate + Double(lagMs) / 1000 : .infinity
                let tm = m < (micUntil ?? n) ? mac0 + Double(m + chunk) / rate : .infinity
                if tb <= tm { sent += s.pushBLE(samples(b..<(b + 240), amp: bleAmp), arrival: tb); b += 240 }
                else { _ = s.appendMic(samples(m..<(m + chunk), amp: macAmp), arrival: tm); m += chunk }
            }
            return (s, sent, m, bleN)
        }
        // 1. level: mic twice as loud as BLE -> raw ratio ~0.5, gain ~0.5 (inside the bounds, not clamped); mic 8x louder -> clamped to the floor
        do {
            let r = session(seconds: 3, bleAmp: 4000, macAmp: 8000, lagMs: 0)
            r.s.measure()
            c("a mic twice as loud gives a ratio near 0.5", abs((r.s.rawRatio ?? 0) - 0.5) < 0.05 && abs(r.s.gain - 0.5) < 0.05)
            let q = session(seconds: 3, bleAmp: 1000, macAmp: 20000, lagMs: 0)
            q.s.measure()
            c("a much louder mic is bounded and the raw ratio is kept", q.s.gain == TailSplicer.minGain && (q.s.rawRatio ?? 1) < 0.2)
            let e = session(seconds: 3, bleAmp: 4000, macAmp: 800, lagMs: 0); e.s.measure()
            c("a much quieter mic is bounded above", e.s.gain == TailSplicer.maxGain)
            let short = session(seconds: 0.4, bleAmp: 4000, macAmp: 8000, lagMs: 0); short.s.measure()
            c("too little speech keeps unity gain", short.s.gain == 1 && short.s.rawRatio == nil)
            let sil = TailSplicer(); for i in 0..<100 { _ = sil.pushBLE([Int16](repeating: 0, count: 240), arrival: mac0 + Double(i + 1) * 0.015); _ = sil.appendMic([Int16](repeating: 0, count: 240), arrival: mac0 + Double(i + 1) * 0.015) }
            sil.measure(); c("silence keeps unity gain", sil.gain == 1)
        }
        // 2. lag: BLE arrives 60 ms later than the mic for the same sound
        do {
            let r = session(seconds: 3, bleAmp: 4000, macAmp: 4000, lagMs: 60)
            r.s.measure()
            c("the lag between the streams is found", abs(r.s.lagMs - 60) <= 10 && (r.s.correlation ?? 0) > 0.9)
            let u = TailSplicer(); var x = 7
            for i in 0..<200 { x = (x &* 1103515245 &+ 12345) & 0x7fffffff; _ = u.pushBLE([Int16](repeating: Int16(x % 3000), count: 240), arrival: mac0 + Double(i + 1) * 0.015); x = (x &* 1103515245 &+ 12345) & 0x7fffffff; _ = u.appendMic([Int16](repeating: Int16(x % 3000), count: 240), arrival: mac0 + Double(i + 1) * 0.015) }
            u.measure(); c("unrelated envelopes are not trusted (lag 0)", u.lagMs == 0)
        }
        // 3. continuity: a ramp that is the same signal in both streams is reproduced exactly, no repeat, no gap, mid-chunk cut
        do {
            let s = TailSplicer(); var sent: [Int16] = []
            let ramp: (Range<Int>) -> [Int16] = { $0.map { Int16(truncatingIfNeeded: $0 % 20000) } }
            var b = 0, m = 0
            let bleEnd = 4800, micEnd = 8160     // BLE up to 0.3 s, mic chunks of 1360 up to 0.51 s
            var lastBLE = 0.0
            while b < bleEnd || m < micEnd {
                let tb = b < bleEnd ? mac0 + Double(b + 240) / rate : .infinity, tm = m < micEnd ? mac0 + Double(m + 1360) / rate : .infinity
                if tb <= tm { sent += s.pushBLE(ramp(b..<(b + 240)), arrival: tb); lastBLE = tb; b += 240 }
                else {
                    if tm > lastBLE + 0.0001 && !s.live && b >= bleEnd { sent += s.splice(lastBLEArrival: lastBLE) }
                    let out = s.appendMic(ramp(m..<(m + 1360)), arrival: tm); if let out { sent += out }; m += 1360
                }
            }
            sent += s.finish()
            c("a cut inside a chunk starts at the computed sample", s.cutIndex == bleEnd && s.live)
            c("BLE then mic reproduce the signal with no gap, repeat or reorder", sent == ramp(0..<micEnd))
            c("the spliced length is the mic audio after the cut plus the cross-fade", s.outputSamples == micEnd - (bleEnd - TailSplicer.crossfade))
        }
        // 4. the cut lies after the newest chunk (backlog 0): the next chunk is trimmed
        do {
            let s = TailSplicer(); var sent: [Int16] = []
            let ramp: (Range<Int>) -> [Int16] = { $0.map { Int16(truncatingIfNeeded: $0 % 20000) } }
            _ = s.appendMic(ramp(0..<1360), arrival: mac0 + 1360 / rate)                 // mic up to 1360
            for p in 0..<7 { sent += s.pushBLE(ramp((p * 240)..<(p * 240 + 240)), arrival: mac0 + Double(p * 240 + 240) / rate + 0.0) }   // BLE up to 1680 > mic
            let out = s.splice(lastBLEArrival: mac0 + 1680 / rate)
            c("a cut after the newest chunk sends nothing yet", out.isEmpty && s.live)
            let next = s.appendMic(ramp(1360..<2720), arrival: mac0 + 2720 / rate) ?? []
            let rest = sent + next
            c("the next chunk is trimmed at the cut and blended over 10 ms", next.count == 2720 - (1680 - TailSplicer.crossfade) && rest.count == 1680 - TailSplicer.crossfade + next.count)
            c("nothing is repeated across the seam", rest == ramp(0..<(1680 - TailSplicer.crossfade)) + ramp((1680 - TailSplicer.crossfade)..<2720))
        }
        // 5. a cut older than the ring: the BLE tail is sent as it was, the ring part follows
        do {
            let s = TailSplicer(); s.maxRingSamples = 800
            let ramp: (Range<Int>) -> [Int16] = { $0.map { Int16(truncatingIfNeeded: $0 % 20000) } }
            for k in 0..<10 { _ = s.appendMic(ramp(k * 400..<(k * 400 + 400)), arrival: mac0 + Double(k * 400 + 400) / rate) }
            var sent: [Int16] = []
            for p in 0..<10 { sent += s.pushBLE(ramp((p * 240)..<(p * 240 + 240)), arrival: mac0 + Double(p * 240 + 240) / rate) }
            sent += s.splice(lastBLEArrival: mac0 + 2400 / rate)
            sent += s.finish()
            c("an old cut keeps every BLE sample and never repeats", sent.count >= 2400 - 0 && Array(sent.prefix(2400 - TailSplicer.crossfade)) == ramp(0..<(2400 - TailSplicer.crossfade)))
        }
        // 6. seam jump: BLE and mic at different levels (gain applied) stay smooth across the seam
        do {
            let r = session(seconds: 3, bleAmp: 4000, macAmp: 8000, lagMs: 0, micUntil: 3 * 16000 + 4080)
            let s = r.s; var sent = r.sent
            sent += s.splice(lastBLEArrival: mac0 + Double(r.bleEnd) / rate)
            var m = r.micEnd
            while m < 3 * 16000 + 4080 { sent += s.appendMic(samples(m..<(m + 1360), amp: 8000), arrival: mac0 + Double(m + 1360) / rate) ?? []; m += 1360 }
            sent += s.finish()
            let seam = r.bleEnd
            // The ideal result is the BLE-level signal itself on both sides of the seam; the blended signal must stay on it.
            let dev = (seam - 400..<seam + 400).map { abs(Int(sent[$0]) - Int(4000 * sig($0))) }.max() ?? 99999
            c("no jump at the seam: the signal stays on the BLE-level curve", dev <= 10)
            c("the mic part is scaled to the BLE level", abs(s.gain - 0.5) < 0.06)
        }
        // 7. pcm <-> data
        let x: [Int16] = [0, 1, -1, 32767, -32768, 1234]
        c("pcm bytes round trip", TailSplicer.samples(TailSplicer.data(x)) == x)
        // 8. without a splice nothing leaves the ring, and the held BLE tail is returned unchanged
        do {
            let s = TailSplicer(); var got = 0
            for i in 0..<10 { got += s.appendMic([Int16](repeating: 5, count: 1000), arrival: 100 + Double(i))?.count ?? 0 }
            c("nothing leaves the ring before AUDIO_STOP", got == 0 && !s.live)
            let b = TailSplicer(); let a = b.pushBLE([Int16](repeating: 7, count: 240), arrival: 100)
            c("the newest 10 ms of BLE audio are held back and returned by finish", a.count == 240 - TailSplicer.crossfade && b.finish().count == TailSplicer.crossfade)
        }
        // 9. the production policy
        do {
            c("keyboard keeps listening 300 ms after the hotkey is released", TailPolicy.keyboardProductionExtraMs == 300)
            c("the remote tail rescue is on, keeps listening 300 ms after key-up and leaves the 21 s firmware stop to the old path", TailPolicy.remoteTailRescueEnabled && TailPolicy.remoteExtraMs == 300 && TailPolicy.firmwareLimitPackets == 1400)
            c("the gain bounds are 0.2 to 4 and the cross-fade is 10 ms", TailSplicer.minGain == 0.2 && TailSplicer.maxGain == 4 && TailSplicer.crossfade == 160)
        }
    }
}
