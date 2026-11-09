import AppKit

enum CapsuleWaitingFixtures {
    static func run(_ c: (String, Bool) -> Void) {
        guard !CharacterAssets.active else { return }
        let capsule = CapsuleWindowController(); capsule.suppressPresentation = true
        capsule.showRecord(elapsed: 0, shortcut: "⌥")
        c("录音条：录音时不转圈", capsule.inspectionWaiting == (false, false))
        capsule.showRecognize()
        c("录音条：识别中声波变模糊，上面转圈", capsule.inspectionWaiting == (true, true))
        capsule.showError("出错了", action: .retry)
        c("录音条：出错时不再转圈，声波不再模糊", capsule.inspectionWaiting == (false, false))
        capsule.showRecognize()
        capsule.hide()
        c("录音条：收起后不再转圈，声波不再模糊", capsule.inspectionWaiting == (false, false))
    }
}
