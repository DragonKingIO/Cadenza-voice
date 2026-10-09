import Foundation
import Accelerate

/// Cleans up a recording before a local model reads it, only as far as the recording needs.
///
///  1. A gentle high-pass at 80 Hz removes rumble and DC. Rumble matters because the levelling step sets its gain from the
///     loudest samples: with a hum in the room it would set the gain from the hum and leave the speech quiet.
///  2. How far the speech stands above the room is estimated from the frame energies. A recording that is already clean is
///     left as it is.
///  3. A recording with a steady room noise close to the speech level gets spectral subtraction: the noise spectrum is learned
///     from the quietest frames and taken out of every frame, never below a floor so the sound stays natural.
/// Everything is on this Mac and on the audio already in memory.
enum SpeechEnhancer {
    static let sampleRate: Float = 16000
    static let frame = 512, hop = 128
    /// A recording with more than this many dB between its loud and quiet frames is clean enough to leave alone.
    static var cleanAboveDB: Float = 24
    /// Chosen by measurement (see docs/LOCAL-MODELS.md): 2.5 with a floor of 0.05 gave the best recognition of soft speech in steady
    /// noise without costing anything in a quiet room; 1.6 / 0.12 recovered about half as much, and stronger settings gained no more.
    static var oversubtraction: Float = 2.5
    static var floorGain: Float = 0.05

    /// Enables or disables everything here (used to compare in the benchmark).
    static var enabled = true

    static func enhance(_ input: [Float]) -> [Float] {
        guard enabled, input.count >= 4000, input.allSatisfy({ $0.isFinite }) else { return input }
        let filtered = highPass(input)
        let snr = estimatedSNR(filtered)
        guard snr < cleanAboveDB else { return filtered }
        return subtract(filtered)
    }

    /// Second-order high-pass (Butterworth, 80 Hz).
    static func highPass(_ x: [Float], cutoff: Float = 80) -> [Float] {
        let w0 = 2 * Float.pi * cutoff / sampleRate, cosw = cos(w0), alpha = sin(w0) / (2 * 0.70710678)
        let a0 = 1 + alpha
        let b0 = (1 + cosw) / 2 / a0, b1 = -(1 + cosw) / a0, b2 = (1 + cosw) / 2 / a0, a1 = -2 * cosw / a0, a2 = (1 - alpha) / a0
        var out = [Float](repeating: 0, count: x.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<x.count {
            let y = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            out[i] = y; x2 = x1; x1 = x[i]; y2 = y1; y1 = y
        }
        return out
    }

    /// Loud frames against quiet frames, in dB (the 90th against the 10th percentile of 20 ms frame energies).
    static func estimatedSNR(_ x: [Float]) -> Float {
        let size = 320
        var energies: [Float] = []
        var i = 0
        while i + size <= x.count { var e: Float = 0; vDSP_svesq(Array(x[i..<(i + size)]), 1, &e, vDSP_Length(size)); energies.append(e / Float(size) + 1e-12); i += size }
        guard energies.count >= 8 else { return 99 }
        let sorted = energies.sorted()
        let low = sorted[Int(Float(sorted.count) * 0.10)], high = sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.90))]
        return 10 * log10(high / low)
    }

    static func subtract(_ input: [Float], oversubtraction: Float = SpeechEnhancer.oversubtraction, floorGain: Float = SpeechEnhancer.floorGain) -> [Float] {
        // Silence is added on both sides so the first and last samples are covered by full windows; at the very edge a window
        // is nearly zero and dividing by its weight would turn rounding error into a spike.
        let pad = frame
        let x = [Float](repeating: 0, count: pad) + input + [Float](repeating: 0, count: pad)
        let processed = subtractPadded(x, oversubtraction: oversubtraction, floorGain: floorGain)
        return Array(processed[pad..<(pad + input.count)])
    }

    private static func subtractPadded(_ x: [Float], oversubtraction: Float, floorGain: Float) -> [Float] {
        let n = frame, bins = n / 2 + 1
        guard x.count >= n * 2, let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD), let inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .INVERSE) else { return x }
        defer { vDSP_DFT_DestroySetup(setup); vDSP_DFT_DestroySetup(inverse) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        let starts = Array(stride(from: 0, through: x.count - n, by: hop))
        // Power spectrum of every frame
        var spectra = [[Float]](repeating: [Float](repeating: 0, count: bins), count: starts.count)
        var reals = [[Float]](), imags = [[Float]]()
        reals.reserveCapacity(starts.count); imags.reserveCapacity(starts.count)
        var inReal = [Float](repeating: 0, count: n / 2), inImag = [Float](repeating: 0, count: n / 2)
        var outReal = [Float](repeating: 0, count: n / 2), outImag = [Float](repeating: 0, count: n / 2)
        for (f, start) in starts.enumerated() {
            var chunk = [Float](repeating: 0, count: n)
            vDSP_vmul(Array(x[start..<(start + n)]), 1, window, 1, &chunk, 1, vDSP_Length(n))
            // Pack even and odd samples as the real-input DFT expects.
            for k in 0..<(n / 2) { inReal[k] = chunk[2 * k]; inImag[k] = chunk[2 * k + 1] }
            vDSP_DFT_Execute(setup, inReal, inImag, &outReal, &outImag)
            reals.append(outReal); imags.append(outImag)
            // Bin 0 and bin n/2 share the first element of the packed form.
            spectra[f][0] = outReal[0] * outReal[0]
            for k in 1..<(n / 2) { spectra[f][k] = outReal[k] * outReal[k] + outImag[k] * outImag[k] }
            spectra[f][n / 2] = outImag[0] * outImag[0]
        }
        // Noise spectrum: the mean power of the quietest 20% of frames
        let frameEnergy = spectra.map { $0.reduce(0, +) }
        let order = frameEnergy.indices.sorted { frameEnergy[$0] < frameEnergy[$1] }
        let quiet = Array(order.prefix(max(4, order.count / 5)))
        var noise = [Float](repeating: 0, count: bins)
        for f in quiet { for k in 0..<bins { noise[k] += spectra[f][k] / Float(quiet.count) } }
        // Gain per frame and bin, smoothed over neighbouring frames so isolated bins do not flicker
        var gains = [[Float]](repeating: [Float](repeating: 1, count: bins), count: starts.count)
        for f in 0..<starts.count {
            for k in 0..<bins {
                let power = max(spectra[f][k], 1e-12)
                gains[f][k] = max(floorGain, 1 - oversubtraction * noise[k] / power).squareRoot()
            }
        }
        for k in 0..<bins {   // smooth over three frames
            var previous = gains[0][k]
            for f in 1..<(starts.count - 1) { let current = gains[f][k]; gains[f][k] = (previous + current + gains[f + 1][k]) / 3; previous = current }
        }
        // Back to the time domain by overlap-add
        var output = [Float](repeating: 0, count: x.count), weight = [Float](repeating: 0, count: x.count)
        for (f, start) in starts.enumerated() {
            var r = reals[f], im = imags[f]
            r[0] *= gains[f][0]; im[0] *= gains[f][n / 2]
            for k in 1..<(n / 2) { r[k] *= gains[f][k]; im[k] *= gains[f][k] }
            var backReal = [Float](repeating: 0, count: n / 2), backImag = [Float](repeating: 0, count: n / 2)
            vDSP_DFT_Execute(inverse, r, im, &backReal, &backImag)
            let scale = 1 / Float(2 * n)   // vDSP's real forward transform doubles and its inverse is unnormalised (factor n)
            for k in 0..<(n / 2) {
                let a = backReal[k] * scale, b = backImag[k] * scale
                output[start + 2 * k] += a * window[2 * k]; weight[start + 2 * k] += window[2 * k] * window[2 * k]
                output[start + 2 * k + 1] += b * window[2 * k + 1]; weight[start + 2 * k + 1] += window[2 * k + 1] * window[2 * k + 1]
            }
        }
        for i in 0..<x.count { output[i] = weight[i] > 1e-4 ? output[i] / weight[i] : x[i] }
        return output
    }
}
