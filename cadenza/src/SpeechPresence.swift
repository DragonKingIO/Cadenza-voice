import Foundation

/// Is there speech in this recording, or only the room? Cloud services and Apple's recognizer will write sentences out of pure
/// noise, so a recording with nothing in it is dropped before anything is inserted.
///
/// The old rule dropped everything whose loudest moment was under a fixed level, which also dropped every whisper. The rule now
/// compares the recording with its own room: speech is a stretch of the recording that stands clearly above the quiet part,
/// however soft. Levels are the meter's readings (rms × 10 per chunk): 0.22 is about -33 dBFS, 0.03 about -50 dBFS.
enum SpeechPresence {
    /// Loud enough that no further question is asked (the old threshold, kept).
    static let loudEnough: Float = 0.22
    /// Below this the signal is near digital silence whatever the room.
    static let floorMinimum: Float = 0.01
    /// How far above the quiet part a chunk must be to count as speech-like.
    static let ratio: Float = 2.5
    /// At least this many chunks, and this share of the recording, must be speech-like: a cough or a tap is not speech.
    static let minimumChunks = 5
    static let minimumShare: Float = 0.12

    static func looksLikeSpeech(peak: Float, levels: [Float]) -> Bool {
        if peak >= loudEnough { return true }
        guard peak >= floorMinimum, levels.count >= 12 else { return false }
        let sorted = levels.sorted()
        let floor = max(0.002, sorted[Int(Float(sorted.count) * 0.15)])
        let threshold = max(floorMinimum, floor * ratio)
        let sustained = levels.filter { $0 >= threshold }.count
        return sustained >= minimumChunks && Float(sustained) / Float(levels.count) >= minimumShare
    }
}
