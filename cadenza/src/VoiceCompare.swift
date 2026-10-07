import SwiftUI
import AppKit
import AVFoundation
import Observation

/// "Compare models with my voice": the person reads a few sentences, and every way of recognizing speech that is actually
/// set up here (installed local models, cloud services with saved credentials and upload consent, the Mac's built-in
/// recognition) recognizes the same recordings. The character error rates are shown side by side. The audio exists only
/// in memory and is dropped when the window closes. It is never written to disk; it leaves this Mac only for the cloud
/// services the person leaves ticked in the list.
@Observable
final class VoiceCompare {
    struct Cell: Equatable { var text: String; var error: Double; var seconds: Double = 0; var failure: String? = nil }
    static let maxClipSeconds = 15.0
    static let minClipSeconds = 0.6
    static let minimumClipsToCompare = 3

    let prompts: [String]
    let candidates: [CompareCandidate]
    /// Ids of the candidates that will take part in the next comparison.
    var selected: Set<String>
    /// Ids of the candidates the current results were produced by.
    private(set) var ran: Set<String> = []
    private(set) var clips: [[Float]?]
    private(set) var results: [[Cell?]] = []
    private(set) var recordingIndex: Int?
    private(set) var level: Float = 0
    private(set) var analyzing = false
    private(set) var message = ""
    private(set) var failedModels: [String] = []

    private let makeCapture: () -> CloudPCMCapturing
    private let recognizer: (CompareCandidate) -> ClipRecognizer?
    private let microphoneUID: String
    private var capture: CloudPCMCapturing?
    private var pcm = Data()
    private var stopTimer: Timer?
    private let lock = NSLock()

    init(prompts: [String], candidates: [CompareCandidate], microphoneUID: String = "",
         makeCapture: @escaping () -> CloudPCMCapturing = { CloudPCMCapture() },
         recognizer: @escaping (CompareCandidate) -> ClipRecognizer?) {
        self.prompts = prompts; self.candidates = candidates; self.microphoneUID = microphoneUID
        self.makeCapture = makeCapture; self.recognizer = recognizer
        selected = Set(candidates.map(\.id))
        clips = Array(repeating: nil, count: prompts.count)
    }

    /// Local models only, each loaded by `loader`. Kept for tests and previews that have no cloud services.
    convenience init(prompts: [String], models: [LocalModelEntry], microphoneUID: String = "",
                     makeCapture: @escaping () -> CloudPCMCapturing = { CloudPCMCapture() },
                     loader: @escaping (LocalModelEntry) -> ((([Float]) -> String))?) {
        self.init(prompts: prompts, candidates: models.map(CompareCandidate.local), microphoneUID: microphoneUID, makeCapture: makeCapture,
                  recognizer: { candidate in candidate.entry.flatMap(loader).map { transcribe in { .text(transcribe($0)) } } })
    }

    /// Sentences to read, in the language the app is set up for.
    static func prompts(forLocale locale: String) -> [String] {
        if locale.lowercased().hasPrefix("zh") {
            return ["今天下午三点开会，请提前十分钟到。", "我想只用本地识别，不想用云端。", "把这段代码提交到 GitHub 上。", "明天我要去北京见李明和王芳。", "为什么识别出来的字总是不对？"]
        }
        return ["Please send the file to the product manager.", "We meet tomorrow at three thirty in the conference room.", "Open the settings and turn on local recognition.", "The invoice total came to two hundred and forty dollars.", "Why does the text come out wrong every time?"]
    }

    /// The local models worth comparing: installed, usable here, and covering the recognition language.
    static func localCandidates(locale: String) -> [LocalModelEntry] {
        LocalModelCenter.shared.installedEntries.filter { LocalModelCatalog.usable($0) && LocalModelCatalog.covers($0, languages: [locale]) }
    }

    // MARK: Recording

    var cloudSelected: [CompareCandidate] { candidates.filter { $0.uploadsAudio && selected.contains($0.id) } }
    func toggle(_ id: String) { guard !analyzing else { return }; if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    var recordedCount: Int { clips.compactMap { $0 }.count }
    var canAnalyze: Bool { !analyzing && recordingIndex == nil && recordedCount >= Self.minimumClipsToCompare && !selected.isEmpty }
    func seconds(_ index: Int) -> Double? { clips.indices.contains(index) ? clips[index].map { Double($0.count) / 16000 } : nil }

    @discardableResult
    func startRecording(_ index: Int) -> Bool {
        guard clips.indices.contains(index), recordingIndex == nil, !analyzing else { return false }
        let source = makeCapture()
        lock.lock(); pcm = Data(); lock.unlock()
        source.onPCM = { [weak self] data in self?.lock.lock(); self?.pcm.append(data); self?.lock.unlock() }
        source.onLevel = { [weak self] value in DispatchQueue.main.async { self?.level = value } }
        guard source.start(uid: microphoneUID) else {
            message = source.lastError ?? L10n.tr("compare.err.mic")
            return false
        }
        capture = source; recordingIndex = index; message = ""
        stopTimer = Timer.scheduledTimer(withTimeInterval: Self.maxClipSeconds, repeats: false) { [weak self] _ in self?.stopRecording() }
        return true
    }

    func stopRecording() {
        guard let index = recordingIndex, let source = capture else { return }
        stopTimer?.invalidate(); stopTimer = nil
        source.stop(); source.onPCM = nil; source.onLevel = nil
        capture = nil; recordingIndex = nil; level = 0
        lock.lock(); let data = pcm; pcm = Data(); lock.unlock()
        let samples = LocalDecoder.samples(fromPCM16: data)
        if Double(samples.count) / 16000 < Self.minClipSeconds {
            message = L10n.tr("compare.err.short")
        } else if !samples.contains(where: { abs($0) > 0.002 }) {
            message = L10n.tr("compare.err.silent")
        } else {
            clips[index] = samples; message = ""
        }
        results = []; ran = []   // older results no longer match the recordings
    }

    /// Test and preview hook: puts a recording in place without a microphone.
    func setClip(_ index: Int, _ samples: [Float]) { if clips.indices.contains(index) { clips[index] = samples; results = []; ran = [] } }

    // MARK: Comparison

    /// Runs every selected candidate on every recording. Local models share the processor, so they run side by side;
    /// each cloud service and the built-in recognizer waits on the network, so those run at the same time as well.
    /// Calls `done` on the main queue.
    func analyze(done: (() -> Void)? = nil) {
        guard canAnalyze else { done?(); return }
        analyzing = true; failedModels = []
        let snapshot = clips, texts = prompts, entries = candidates, chosen = selected
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var table = [[Cell?]](repeating: [Cell?](repeating: nil, count: entries.count), count: texts.count)
            var failed: [String] = []
            let guardLock = NSLock(), group = DispatchGroup()
            func run(_ m: Int) {
                guard let transcribe = self?.recognizer(entries[m]) else { guardLock.lock(); failed.append(entries[m].id); guardLock.unlock(); return }
                for (p, clip) in snapshot.enumerated() {
                    guard let clip else { continue }
                    let started = ProcessInfo.processInfo.systemUptime
                    let outcome = transcribe(clip)
                    let seconds = ProcessInfo.processInfo.systemUptime - started
                    let cell: Cell
                    switch outcome {
                    case .text(let text): cell = Cell(text: text, error: AccuracyBenchmark.cer(reference: texts[p], hypothesis: text), seconds: seconds)
                    case .failed(let reason): cell = Cell(text: "", error: 1, seconds: seconds, failure: reason.isEmpty ? L10n.tr("compare.err.failed") : reason)
                    }
                    guardLock.lock(); table[p][m] = cell; guardLock.unlock()
                }
            }
            let active = entries.indices.filter { chosen.contains(entries[$0].id) }
            let locals = active.filter { entries[$0].kind == .local }
            for m in active where entries[m].kind != .local {
                group.enter(); DispatchQueue.global(qos: .userInitiated).async { run(m); group.leave() }
            }
            DispatchQueue.concurrentPerform(iterations: locals.count) { run(locals[$0]) }
            group.wait()
            DispatchQueue.main.async {
                guard let self else { return }
                self.results = table; self.failedModels = failed; self.ran = Set(active.map { entries[$0].id }); self.analyzing = false
                done?()
            }
        }
    }

    /// Mean character error rate per model over the sentences that were recorded; nil when a model produced nothing.
    func averageError(_ model: Int) -> Double? {
        let cells = results.compactMap { row in row.indices.contains(model) ? row[model] : nil }.filter { $0.failure == nil }
        return cells.isEmpty ? nil : cells.reduce(0) { $0 + min(1, $1.error) } / Double(cells.count)
    }
    /// Average time to recognize one sentence. Models run side by side, so this is a guide to relative speed.
    func averageSeconds(_ model: Int) -> Double? {
        let cells = results.compactMap { row in row.indices.contains(model) ? row[model] : nil }.filter { $0.failure == nil }
        return cells.isEmpty ? nil : cells.reduce(0) { $0 + $1.seconds } / Double(cells.count)
    }
    /// The reason a candidate could not recognize anything, when every one of its recordings failed.
    func failureReason(_ model: Int) -> String? {
        let cells = results.compactMap { row in row.indices.contains(model) ? row[model] : nil }
        guard !cells.isEmpty, cells.allSatisfy({ $0.failure != nil }) else { return nil }
        return cells.first?.failure
    }
    static let punctuation = Set("，。！？、；：,.!?;:")
    /// True when the model wrote no punctuation at all although the sentences it heard contain punctuation.
    func writesNoPunctuation(_ model: Int) -> Bool {
        var seen = 0
        for (p, row) in results.enumerated() where row.indices.contains(model) {
            guard let cell = row[model], !cell.text.isEmpty, prompts[p].contains(where: { Self.punctuation.contains($0) }) else { continue }
            seen += 1
            if cell.text.contains(where: { Self.punctuation.contains($0) }) { return false }
        }
        return seen >= 2
    }
    /// The model with the lowest average error. A tie within one percentage point counts as no clear winner.
    var bestModel: Int? {
        let scored = candidates.indices.compactMap { m in averageError(m).map { (m, $0) } }.sorted { $0.1 < $1.1 }
        guard let first = scored.first else { return nil }
        if scored.count > 1, scored[1].1 - first.1 < 0.01 { return nil }
        return first.0
    }

    /// Drops every recording and result. Called when the window closes.
    func clear() {
        if recordingIndex != nil { stopRecording() }
        stopTimer?.invalidate(); stopTimer = nil
        lock.lock(); pcm = Data(); lock.unlock()
        clips = Array(repeating: nil, count: prompts.count); results = []; ran = []; message = ""
    }
}

// MARK: - View

struct VoiceCompareView: View {
    @Bindable var compare: VoiceCompare
    var model: SettingsModel
    var close: () -> Void
    @State private var micAllowed = HoldNativeEngine.micAuthorized()

    private var busyElsewhere: Bool { model.listening || model.recognizing }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(L10n.tr("compare.intro")).font(.callout).foregroundStyle(.primary)
                    Label(L10n.tr("compare.privacy"), systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
                    if compare.candidates.count < 2 { Label(L10n.tr("compare.oneModel"), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
                    if !micAllowed { Label(L10n.tr("compare.err.micDenied"), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                }
                Section {
                    ForEach(compare.candidates) { candidateRow($0) }
                } header: { Text(L10n.tr("compare.who")) } footer: {
                    if !compare.cloudSelected.isEmpty {
                        Label(L10n.format("compare.uploadNote", compare.cloudSelected.map(\.name).joined(separator: "、")), systemImage: "icloud.and.arrow.up")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                Section {
                    ForEach(compare.prompts.indices, id: \.self) { i in promptRow(i) }
                } header: { Text(L10n.tr("compare.sentences")) } footer: {
                    if !compare.message.isEmpty { Text(compare.message).font(.callout).foregroundStyle(.orange) }
                }
                if !compare.results.isEmpty { resultsSection }
            }.formStyle(.grouped)
            Divider()
            HStack {
                if compare.analyzing { ProgressView().controlSize(.small); Text(L10n.tr("compare.analyzing")).font(.callout).foregroundStyle(.secondary) }
                else { Text(L10n.format("compare.recorded", compare.recordedCount, compare.prompts.count)).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button(L10n.tr("compare.close")) { compare.clear(); close() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("compare.run")) { compare.analyze() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!compare.canAnalyze)
            }.padding(16)
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { micAllowed = HoldNativeEngine.micAuthorized() }
        .onDisappear { compare.clear() }
    }

    @ViewBuilder private func candidateRow(_ candidate: CompareCandidate) -> some View {
        Toggle(isOn: Binding(get: { compare.selected.contains(candidate.id) }, set: { _ in compare.toggle(candidate.id) })) {
            HStack(spacing: 8) {
                Text(candidate.name)
                switch candidate.kind {
                case .local: badge(L10n.tr("compare.kind.local"), .secondary)
                case .system: badge(L10n.tr("compare.kind.system"), .secondary)
                case .cloud: badge(L10n.tr("compare.kind.cloud"), .orange)
                }
            }
        }.disabled(compare.analyzing)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }

    @ViewBuilder private func promptRow(_ i: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(compare.prompts[i])
                if compare.recordingIndex == i {
                    HStack(spacing: 6) { Image(systemName: "waveform").foregroundStyle(.red); ProgressView(value: Double(compare.level)).frame(width: 90) }
                } else if let s = compare.seconds(i) {
                    Label(String(format: L10n.tr("compare.clip"), s), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
            }
            Spacer()
            if compare.recordingIndex == i {
                Button(L10n.tr("compare.stop")) { compare.stopRecording() }.buttonStyle(.borderedProminent).tint(.red)
            } else {
                Button(L10n.tr(compare.seconds(i) == nil ? "compare.record" : "compare.rerecord")) {
                    micAllowed = HoldNativeEngine.micAuthorized()
                    if TCC.micStatus() == .notDetermined { TCC.requestMic { _ in DispatchQueue.main.async { micAllowed = HoldNativeEngine.micAuthorized() } } }
                    else { compare.startRecording(i) }
                }.buttonStyle(.bordered).disabled(compare.recordingIndex != nil || compare.analyzing || busyElsewhere || !micAllowed)
            }
        }
    }

    private var ranIndices: [Int] { compare.candidates.indices.filter { compare.ran.contains(compare.candidates[$0].id) } }

    @ViewBuilder private func useButton(_ candidate: CompareCandidate) -> some View {
        let current: Bool = {
            switch candidate.kind {
            case .local: return model.engine == .local && model.localSettings.primaryModelID == candidate.id
            case .cloud: return candidate.engine == model.engine
            case .system: return model.engine == .apple
            }
        }()
        if current {
            Text(L10n.tr("compare.inUse")).font(.callout).foregroundStyle(.secondary)
        } else {
            Button(L10n.tr("compare.use")) {
                switch candidate.kind {
                case .local: model.selectLocalModel(candidate.id, ready: compare.candidates.compactMap(\.entry))
                case .cloud, .system: if let engine = candidate.engine { model.selectEngine(engine) }
                }
            }.buttonStyle(.bordered).disabled(compare.failedModels.contains(candidate.id) || busyElsewhere)
        }
    }

    @ViewBuilder private var resultsSection: some View {
        Section {
            ForEach(ranIndices, id: \.self) { m in
                let candidate = compare.candidates[m]
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(candidate.name).fontWeight(.semibold)
                            if candidate.uploadsAudio { badge(L10n.tr("compare.kind.cloud"), .orange) }
                            if compare.bestModel == m { Text(L10n.tr("compare.best")).font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(Color.green.opacity(0.2), in: Capsule()).foregroundStyle(.green) }
                        }
                        if compare.failedModels.contains(candidate.id) { Text(L10n.tr("compare.loadFailed")).font(.caption).foregroundStyle(.orange) }
                        else if let reason = compare.failureReason(m) { Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        else if let e = compare.averageError(m) {
                            Text(String(format: L10n.tr("compare.error"), e * 100) + (compare.averageSeconds(m).map { " · " + String(format: L10n.tr(candidate.kind == .local ? "compare.time" : "compare.timeWait"), $0) } ?? "")).font(.callout).foregroundStyle(.secondary)
                            if compare.writesNoPunctuation(m) { Label(L10n.tr("compare.noPunct"), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    Spacer()
                    useButton(candidate)
                }
            }
        } header: { Text(L10n.tr("compare.results")) } footer: { Text(L10n.tr("compare.resultsNote")).font(.callout).foregroundStyle(.secondary) }

        Section {
            ForEach(compare.prompts.indices, id: \.self) { p in
                if compare.clips[p] != nil, compare.results.indices.contains(p) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(compare.prompts[p]).font(.callout).foregroundStyle(.secondary)
                        ForEach(ranIndices, id: \.self) { m in
                            if let cell = compare.results[p][m] {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(compare.candidates[m].name).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading).lineLimit(1)
                                    if cell.failure != nil { Text(L10n.tr("compare.failedClip")).foregroundStyle(.orange) }
                                    else { Text(cell.text.isEmpty ? L10n.tr("compare.nothing") : cell.text).foregroundStyle(cell.error == 0 ? Color.green : (cell.error < 0.2 ? Color.primary : Color.orange)) }
                                }
                            }
                        }
                    }.padding(.vertical, 2)
                }
            }
        } header: { Text(L10n.tr("compare.details")) }
    }
}
