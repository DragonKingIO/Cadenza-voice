import AVFoundation
import CoreAudio
import AudioToolbox

struct MicrophoneDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum Microphones {
    static func devices() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            func string(_ selector: AudioObjectPropertySelector) -> String? {
                var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var value: Unmanaged<CFString>?
                var length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(id, &a, 0, nil, &length, &value) == noErr else { return nil }
                return value?.takeRetainedValue() as String?
            }
            guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName) else { return nil }
            guard !name.hasPrefix("CADefaultDeviceAggregate-") else { return nil }
            return MicrophoneDevice(id: id, uid: uid, name: name)
        }
    }

    static func configure(_ engine: AVAudioEngine, uid: String) -> String? {
        guard !uid.isEmpty else { return nil }
        guard var device = devices().first(where: { $0.uid == uid })?.id else { return L10n.tr("ui.d07d15b0cb01") }
        guard let unit = engine.inputNode.audioUnit else { return L10n.tr("ui.1d8267ad1c66") }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr ? nil : L10n.format("ui.6c3fae64417c", String(describing: status))
    }
}
