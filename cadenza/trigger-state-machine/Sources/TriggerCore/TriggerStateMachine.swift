// No UI, OS events, audio, network, timers, or localized strings are executed here.
// The coordinator executes returned actions, in order, and tags callbacks with sessionID.
public protocol TriggerClock {
    var now: Double { get } // Monotonic seconds, injected by the caller.
}

public struct TriggerStateMachine<Clock: TriggerClock> {
    public enum State: String, CaseIterable { case idle, armed, holding, locked, recognizing, inserting, cancelled, error }
    public enum Mode { case hybrid, hold, toggle }
    public enum Binding { case primary, independentToggle }
    public enum Submission { case streaming, wholeRecording }
    public enum Access: Equatable { case local, cloud(consented: Bool) }
    public enum Feedback: Equatable {
        case tooShort, noSpeech, chordCancelled, escaped, bufferFull
        case microphoneDenied, credentialsMissing, uploadConsentRequired, captureFailed
        case recognitionFailed, noText, copiedToClipboard, insertionFailed
    }
    public enum Recognition: Equatable { case text(String), noText, failed }
    public enum Insertion: Equatable { case inserted, copiedToClipboard, failed }
    public enum Event: Equatable {
        case keyDown(binding: Binding, isRepeat: Bool, standaloneModifier: Bool)
        case keyUp(binding: Binding)
        case otherKeyDown
        case escape
        case timerFired(sessionID: UInt64)
        // duration is the number of newly captured, valid PCM frames / sample rate.
        // speechDetected comes from a shared local detector, never an ASR transcript.
        case audioLevel(sessionID: UInt64, validDuration: Double, speechDetected: Bool)
        case recognitionResult(sessionID: UInt64, Recognition)
        case insertionResult(sessionID: UInt64, Insertion)
        case captureFailed(sessionID: UInt64)
        case bufferOverflow(sessionID: UInt64)
        case reset
        case stopRequested
        case cancelRequested
    }
    public enum Action: Equatable {
        case startCapture(sessionID: UInt64, bufferLimitBytes: Int)
        case installEscapeMonitor
        case removeEscapeMonitor
        case scheduleTimers(sessionID: UInt64)
        case cancelTimers(sessionID: UInt64)
        // Must check consent again, flush the bounded buffer once, then stream.
        case startStreaming(sessionID: UInt64)
        case uploadWholeRecording(sessionID: UInt64)
        case stopCapture
        case discardAudio
        case stopStreaming
        case recognize(sessionID: UInt64)
        // Coordinator rechecks current editable focus, otherwise copies and reports.
        case insertOrCopy(sessionID: UInt64, text: String)
        case feedback(Feedback)
    }
    public struct Configuration {
        public let mode: Mode
        public let longPressThreshold: Double
        public let lockedSilenceTimeout: Double
        public let speechSilenceTimeout: Double
        public let submission: Submission
        public let engineMaximumDuration: Double
        public let minimumAudioDuration: Double
        public let minimumTapDuration: Double
        public let bufferLimitBytes: Int
        public let access: Access
        public let microphoneAllowed: Bool
        public let credentialsAvailable: Bool
        public let independentToggleEnabled: Bool
        public enum Invalid: Error { case threshold, silenceTimeout, maximumDuration, minimumAudio, minimumTap, bufferLimit }
        public init(mode: Mode = .hybrid, longPressThreshold: Double = 0.300,
                    lockedSilenceTimeout: Double = 10, speechSilenceTimeout: Double = 20,
                    submission: Submission = .streaming, engineMaximumDuration: Double = 60,
                    minimumAudioDuration: Double = 0.5, minimumTapDuration: Double = 0.060,
                    bufferLimitBytes: Int = 64_000, access: Access = .local,
                    microphoneAllowed: Bool = true, credentialsAvailable: Bool = true,
                    independentToggleEnabled: Bool = false) throws {
            guard longPressThreshold.isFinite, (0.2...0.6).contains(longPressThreshold) else {throw Invalid.threshold}
            guard lockedSilenceTimeout.isFinite, lockedSilenceTimeout > 0 else {throw Invalid.silenceTimeout}
            guard speechSilenceTimeout.isFinite, speechSilenceTimeout > 0 else {throw Invalid.silenceTimeout}
            guard engineMaximumDuration.isFinite, engineMaximumDuration >= minimumAudioDuration else {throw Invalid.maximumDuration}
            guard minimumAudioDuration.isFinite, minimumAudioDuration >= 0.5 else {throw Invalid.minimumAudio}
            guard minimumTapDuration.isFinite, minimumTapDuration >= 0, minimumTapDuration < longPressThreshold else {throw Invalid.minimumTap}
            guard bufferLimitBytes > 0 else {throw Invalid.bufferLimit}
            self.mode=mode; self.longPressThreshold=longPressThreshold
            self.lockedSilenceTimeout=lockedSilenceTimeout; self.speechSilenceTimeout=speechSilenceTimeout;self.submission=submission; self.engineMaximumDuration=engineMaximumDuration
            self.minimumAudioDuration=minimumAudioDuration; self.minimumTapDuration=minimumTapDuration
            self.bufferLimitBytes=bufferLimitBytes; self.access=access
            self.microphoneAllowed=microphoneAllowed; self.credentialsAvailable=credentialsAvailable
            self.independentToggleEnabled=independentToggleEnabled
        }
    }
    public struct Output: Equatable {
        public let state: State
        public let actions: [Action]
    }
    public private(set) var state: State = .idle
    public private(set) var sessionID: UInt64 = 0
    public private(set) var submissionCommitted = false
    public private(set) var validAudioDuration: Double = 0
    public var isRecording: Bool { state == .armed || state == .holding || state == .locked }
    public var shouldInterceptEscape: Bool { isRecording }
    private let clock: Clock
    private let configuration: Configuration
    private var start: Double = 0
    private var lockedAt: Double = 0
    private var lastSpeechAt: Double?
    private var activeBinding: Binding = .primary
    private var activeMode: Mode = .hybrid
    private var physicalDown = false
    private var modifierDown = false

    public init(clock: Clock, configuration: Configuration) {self.clock=clock;self.configuration=configuration}

    @discardableResult public mutating func handle(_ event: Event) -> Output {
        var actions: [Action] = []
        switch event {
        case let .keyDown(binding, repeated, standalone):
            guard !repeated, state != .recognizing, state != .inserting else {return output([])}
            guard binding != .independentToggle || configuration.independentToggleEnabled else {return output([])}
            if state == .locked { actions=finishRecording() }
            else if !isRecording, !physicalDown {
                if let refusal=refusalReason() {state = .error;actions=[.feedback(refusal)]}
                else {
                    sessionID += 1; start=clock.now; lockedAt=0; lastSpeechAt=nil
                    validAudioDuration=0; submissionCommitted=false
                    activeBinding=binding;activeMode=binding == .independentToggle ? .toggle:configuration.mode
                    physicalDown=true;modifierDown=standalone;state = .armed
                    actions=[.startCapture(sessionID:sessionID,bufferLimitBytes:configuration.bufferLimitBytes),
                             .installEscapeMonitor,.scheduleTimers(sessionID:sessionID)]
                    if !standalone {actions += commit()}
                }
            }
        case let .keyUp(binding):
            guard binding == activeBinding, physicalDown else {return output([])}
            physicalDown=false;modifierDown=false
            if state == .holding {actions=finishRecording()}
            else if state == .armed {
                let held=clock.now-start
                if activeMode == .hold || activeMode == .hybrid && held >= configuration.longPressThreshold {
                    // A delayed timer cannot turn a long press into a toggle.
                    actions=finishRecording()
                } else if held < configuration.minimumTapDuration {actions=cancel(.tooShort)}
                else {state = .locked;lockedAt=clock.now;actions=commit()}
            }
        case .otherKeyDown:
            if isRecording && modifierDown {actions=cancel(.chordCancelled)}
        case .escape:
            if isRecording {actions=cancel(.escaped)}
        case let .timerFired(id):
            guard id == sessionID, isRecording else {return output([])}
            if clock.now-start >= configuration.engineMaximumDuration {actions=finishRecording()}
            else if state == .locked, let spoken=lastSpeechAt, clock.now-max(lockedAt,spoken) >= configuration.speechSilenceTimeout {
                actions=finishRecording()
            } else if state == .locked, lastSpeechAt == nil, clock.now-lockedAt >= configuration.lockedSilenceTimeout {
                actions=cancel(.noSpeech)
            } else if state == .armed, activeMode != .toggle, clock.now-start >= configuration.longPressThreshold {
                state = .holding;actions=commit()
            }
        case let .audioLevel(id, duration, speech):
            guard id == sessionID, isRecording, duration.isFinite, duration >= 0 else {return output([])}
            validAudioDuration += duration
            if speech && duration > 0 {lastSpeechAt=clock.now}
        case let .recognitionResult(id, result):
            guard id == sessionID, state == .recognizing else {return output([])}
            switch result {
            case let .text(text) where text.contains(where:{ !$0.isWhitespace }):
                state = .inserting;actions=[.insertOrCopy(sessionID:sessionID,text:text)]
            case .text, .noText: state = .error;actions=[.feedback(.noText)]
            case .failed: state = .error;actions=[.feedback(.recognitionFailed)]
            }
        case let .insertionResult(id, result):
            guard id == sessionID, state == .inserting else {return output([])}
            switch result {
            case .inserted:state = .idle
            case .copiedToClipboard:state = .idle;actions=[.feedback(.copiedToClipboard)]
            case .failed:state = .error;actions=[.feedback(.insertionFailed)]
            }
        case let .captureFailed(id):
            if id == sessionID, isRecording {actions=cancel(.captureFailed);state = .error}
        case let .bufferOverflow(id):
            if id == sessionID, isRecording {actions=cancel(.bufferFull);state = .error}
        case .stopRequested:
            if isRecording {actions=finishRecording()}
        case .cancelRequested:
            if isRecording {actions=cancel(.escaped)}
        case .reset:
            if !isRecording && state != .recognizing && state != .inserting {state = .idle}
        }
        return output(actions)
    }
    private func output(_ actions:[Action])->Output {Output(state:state,actions:actions)}
    private func refusalReason()->Feedback? {
        if !configuration.microphoneAllowed {return .microphoneDenied}
        if case .cloud(let consented)=configuration.access {
            if !consented {return .uploadConsentRequired}
            if !configuration.credentialsAvailable {return .credentialsMissing}
        }
        return nil
    }
    private mutating func commit()->[Action] {
        guard configuration.submission == .streaming, !submissionCommitted else {return []}
        guard refusalReason() == nil else {return cancel(.uploadConsentRequired)}
        submissionCommitted=true
        return [.startStreaming(sessionID:sessionID)]
    }
    private func stopActions()->[Action] {
        [.stopCapture,.removeEscapeMonitor,.cancelTimers(sessionID:sessionID)]
    }
    private mutating func finishRecording()->[Action] {
        guard validAudioDuration >= configuration.minimumAudioDuration else {return cancel(.tooShort)}
        if configuration.submission == .wholeRecording && lastSpeechAt == nil {return cancel(.noSpeech)}
        var actions=stopActions()
        if configuration.submission == .wholeRecording {
            guard refusalReason() == nil else {return cancel(.uploadConsentRequired)}
            submissionCommitted=true; actions += [.uploadWholeRecording(sessionID:sessionID)]
        } else { actions += commit() }
        state = .recognizing;actions += [.stopStreaming,.recognize(sessionID:sessionID)]
        return actions
    }
    private mutating func cancel(_ reason:Feedback)->[Action] {
        var actions=stopActions()
        if submissionCommitted {actions += [.stopStreaming]}
        state = .cancelled
        actions += [.discardAudio,.feedback(reason)]
        return actions
    }
}
