import AVFoundation

/// Exact digital silence check, not a VAD or proof that a human spoke.
/// Keeps only signal presence and sample count; never keeps audio samples.
final class AudioSignalEvidence {
    private let lock=NSLock()
    private var signal=false
    private var samples=0
    private var unsupported=false
    var hasSignal:Bool? {lock.lock();defer{lock.unlock()};return unsupported ? nil:signal}
    func reset(){lock.lock();signal=false;samples=0;unsupported=false;lock.unlock()}
    func observe(_ values:UnsafeBufferPointer<Float>) {
        let found=values.contains{$0.isFinite && $0 != 0}
        lock.lock();samples += values.count;signal = signal || found;lock.unlock()
    }
    func observe(_ buffer:AVAudioPCMBuffer) {
        let channels=Int(buffer.format.channelCount),frames=Int(buffer.frameLength)
        let count=buffer.format.isInterleaved ? frames*channels:frames
        let pointers=buffer.format.isInterleaved ? 1:channels
        if let data=buffer.floatChannelData {
            for c in 0..<pointers {observe(UnsafeBufferPointer(start:data[c],count:count))}
        } else if let data=buffer.int16ChannelData {
            for c in 0..<pointers {record(found:UnsafeBufferPointer(start:data[c],count:count).contains{$0 != 0},count:count)}
        } else if let data=buffer.int32ChannelData {
            for c in 0..<pointers {record(found:UnsafeBufferPointer(start:data[c],count:count).contains{$0 != 0},count:count)}
        } else {lock.lock();unsupported=true;lock.unlock()}
    }
    private func record(found:Bool,count:Int) {lock.lock();signal = signal || found;samples += count;lock.unlock()}
}
