import Foundation

/// Fixed byte strings and in-memory settings only: no Bluetooth, no input devices, no files.
enum HardwareRemoteFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("Hardware remote " + name, ok) }

        // IMA ADPCM, high nibble first: 0x70 is nibble 7 (+11, step index 0 -> 8) and then nibble 0 (+2 at step 16).
        var decoder = RemoteIMAADPCMDecoder()
        c("adpcm: a byte decodes to two little-endian samples, high nibble first",
          decoder.decode(adpcmData: Data([0x70])) == Data([0x0B, 0x00, 0x0D, 0x00]) && decoder.predictor == 13 && decoder.stepIndex == 7)
        var negative = RemoteIMAADPCMDecoder()
        c("adpcm: the sign bit subtracts", negative.decodeNibble(0x0F) == -11)
        var clamped = RemoteIMAADPCMDecoder()
        clamped.reset(initialPredictor: 70_000, initialIndex: 500)
        c("adpcm: predictor and step index stay in range", clamped.predictor == 32767 && clamped.stepIndex == 88
          && clamped.decodeNibble(0x07) == 32767 && clamped.stepIndex == 88)
        var gain = RemoteIMAADPCMDecoder()
        gain.reset(initialPredictor: 20_000)
        c("adpcm: gain is applied and clipped", gain.decodeNibble(0x00, gain: 4) == 32767)
        var length = RemoteIMAADPCMDecoder()
        c("adpcm: 16 kHz output is four bytes per input byte", length.decode(adpcmData: Data(repeating: 0x11, count: 20)).count == 80)

        // Key actions: only the voice key may hold a voice action.
        var config = HardwareRemoteConfig()
        c("config: defaults hold to talk on the voice key", config.action(for: .voice) == .holdToTalk && config.action(for: .ok) == .confirmReturn)
        config.setAction(.toggleVoice, for: .voice)
        c("config: the voice key can switch to press-to-talk", config.action(for: .voice) == .toggleVoice)
        config.setAction(.copyShortcut, for: .voice)
        c("config: the voice key never takes a non-voice action", config.action(for: .voice) == .holdToTalk)
        config.setAction(.holdToTalk, for: .menu)
        c("config: another key never takes a voice action", config.action(for: .menu) == .copyLastResult)
        config.setAction(.disabled, for: .power)
        config.keyMappings[HardwareRemoteKey.tv.rawValue] = "not-an-action"
        c("config: an unknown stored action falls back to the key's default", config.action(for: .tv) == .startDirectOCR && config.action(for: .power) == .disabled)
        c("config: every key has a default action", HardwareRemoteKey.allCases.allSatisfy { HardwareRemoteConfig.defaultVoiceAssistantMappings[$0.rawValue] != nil })

        // 66 actions in groups, three presets, repeat behaviour and the level bar.
        c("actions: every action belongs to a group with a title", HardwareRemoteAction.allCases.allSatisfy { !$0.group.title.isEmpty && !$0.displayName.isEmpty })
        c("actions: the voice actions are the only ones in the voice group", HardwareRemoteAction.allCases.filter { $0.group == .voice } .allSatisfy { $0.isVoiceAction } && HardwareRemoteAction.voiceKeyOptions.contains(.holdToTranslate))
        for preset in HardwareRemotePreset.allCases {
            let m = HardwareRemoteConfig.mappings(for: preset)
            c("preset \(preset.rawValue): maps every key to a real action and only the voice key to a voice action",
              HardwareRemoteKey.allCases.allSatisfy { key in
                  guard let raw = m[key.rawValue], let act = HardwareRemoteAction(rawValue: raw) else { return false }
                  return act.isVoiceAction == key.isDedicatedVoiceKey
              } && !preset.title.isEmpty)
        }
        var applied = HardwareRemoteConfig(); applied.keyMappings = HardwareRemoteConfig.mappings(for: .editing)
        c("preset editing: arrows select text", applied.action(for: .up) == .selectUp && applied.action(for: .menu) == .cutShortcut)
        let normalizer = RemoteLevelNormalizer()
        c("level bar: a quiet voice still moves the bar and the peak is 1", normalizer.normalized(0.005) == 0.25 && normalizer.normalized(0.02) == 1 && normalizer.normalized(0) == 0)
        let decoded = (try? JSONDecoder().decode(HardwareRemoteConfig.self, from: JSONEncoder().encode(config)))
        c("config: survives encoding", decoded == config)
    }
}
