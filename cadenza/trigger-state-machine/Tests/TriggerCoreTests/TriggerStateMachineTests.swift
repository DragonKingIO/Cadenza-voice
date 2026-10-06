import Testing
@testable import TriggerCore

final class FakeClock: TriggerClock {
    var now: Double = 0
    func advance(_ seconds: Double) {now += seconds}
}
private typealias Machine = TriggerStateMachine<FakeClock>

@Suite struct TriggerStateMachineTests {
    private let primaryDown = Machine.Event.keyDown(binding:.primary,isRepeat:false,standaloneModifier:true)
    private let primaryUp = Machine.Event.keyUp(binding:.primary)
    private func make(_ config: Machine.Configuration? = nil) throws -> (FakeClock, Machine) {
        let clock=FakeClock()
        return (clock,Machine(clock:clock,configuration:try config ?? Machine.Configuration()))
    }
    private func audio(_ machine: inout Machine, duration:Double=0.6, speech:Bool=true) {
        machine.handle(.audioLevel(sessionID:machine.sessionID,validDuration:duration,speechDetected:speech))
    }
    private func lock(_ machine: inout Machine, _ clock: FakeClock) {
        machine.handle(primaryDown);clock.advance(0.1);machine.handle(primaryUp)
    }
    private func timer(_ machine: inout Machine) -> Machine.Output {
        machine.handle(.timerFired(sessionID:machine.sessionID))
    }
    @Test func testDownStartsCaptureImmediatelyWithoutSubmission() throws {
        let (_,m)=try make();var machine=m
        let result=machine.handle(primaryDown)
        #expect((result.state) == (.armed))
        #expect((result.actions) == ([.startCapture(sessionID:1,bufferLimitBytes:64_000),.installEscapeMonitor,.scheduleTimers(sessionID:1)]))
        #expect(!(machine.submissionCommitted))
    }
    @Test func testLongPressFlushesAtThresholdOnceThenReleaseRecognizes() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown)
        clock.now=0.299;#expect((timer(&machine).state) == (.armed))
        clock.now=0.300
        #expect((timer(&machine).actions) == ([.startStreaming(sessionID:1)]))
        #expect((machine.state) == (.holding));#expect((timer(&machine).actions) == ([]))
        clock.now=1;audio(&machine)
        let result=machine.handle(primaryUp)
        #expect((result.state) == (.recognizing))
        #expect((result.actions) == ([.stopCapture,.removeEscapeMonitor,.cancelTimers(sessionID:1),.stopStreaming,.recognize(sessionID:1)]))
    }
    @Test func testShortPressLocksAndSecondDownStopsImmediately() throws {
        let (clock,m)=try make();var machine=m
        lock(&machine,clock);#expect((machine.state) == (.locked));#expect(machine.submissionCommitted)
        audio(&machine);clock.advance(1)
        #expect((machine.handle(primaryDown).state) == (.recognizing))
        #expect((machine.handle(primaryUp).actions) == ([]))
    }
    @Test func testExtremelyShortTapDiscardsWithoutSubmission() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown);clock.advance(0.01)
        let result=machine.handle(primaryUp)
        #expect((result.state) == (.cancelled));#expect(result.actions.contains(.discardAudio))
        #expect(result.actions.contains(.feedback(.tooShort)));#expect(!(machine.submissionCommitted))
    }
    @Test func testExactlyMinimumTapLocks() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown);clock.now=0.060
        #expect((machine.handle(primaryUp).state) == (.locked))
    }
    @Test func testTimerDelayedPastLongReleaseDoesNotLock() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown);clock.now=1;audio(&machine)
        let result=machine.handle(primaryUp)
        #expect((result.state) == (.recognizing))
        #expect((result.actions.filter { $0 == .startStreaming(sessionID:1) }.count) == (1))
    }
    @Test func testReleaseExactlyThresholdCountsAsHoldNotToggle() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown);clock.now=0.3
        #expect((machine.handle(primaryUp).state) == (.cancelled))
        #expect(!(machine.submissionCommitted))
    }
    @Test func testChordBeforeThresholdDiscardsWithZeroCommitActions() throws {
        let (clock,m)=try make();var machine=m
        var trace=machine.handle(primaryDown).actions;clock.advance(0.2)
        trace += machine.handle(.otherKeyDown).actions
        #expect((machine.state) == (.cancelled));#expect(trace.contains(.discardAudio))
        #expect(!(trace.contains(.startStreaming(sessionID:1))))
        clock.advance(1);#expect((timer(&machine).actions) == ([]))
        #expect((machine.handle(primaryUp).actions) == ([]))
    }
    @Test func testChordAfterCommitStopsStreamCannotUndoEarlierSubmission() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown);clock.now=0.3;_ = timer(&machine)
        let result=machine.handle(.otherKeyDown)
        #expect((result.state) == (.cancelled));#expect(result.actions.contains(.stopStreaming))
        #expect(machine.submissionCommitted)
    }
    @Test func testRegularTypingInLockedDoesNotCancel() throws {
        let (clock,m)=try make();var machine=m;lock(&machine,clock)
        #expect((machine.handle(.otherKeyDown).state) == (.locked))
        #expect((machine.handle(.otherKeyDown).actions) == ([]))
    }
    @Test func testEscapeWhileArmedCancelsWithNoSubmission() throws {
        let (_,m)=try make();var machine=m;machine.handle(primaryDown)
        #expect(machine.shouldInterceptEscape)
        let result=machine.handle(.escape)
        #expect((result.state) == (.cancelled));#expect(result.actions.contains(.removeEscapeMonitor))
        #expect(!(machine.shouldInterceptEscape));#expect(!(machine.submissionCommitted))
    }
    @Test func testEscapeWhileLockedStopsAlreadyCommittedStream() throws {
        let (clock,m)=try make();var machine=m;lock(&machine,clock)
        let result=machine.handle(.escape)
        #expect((result.state) == (.cancelled));#expect(result.actions.contains(.discardAudio))
        #expect(result.actions.contains(.stopStreaming));#expect(machine.submissionCommitted)
    }
    @Test func testEscapeDuringHoldingCancels() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown);clock.now=0.3;_ = timer(&machine)
        #expect((machine.handle(.escape).state) == (.cancelled))
    }
    @Test func testEscapeOutsideRecordingIsIgnored() throws {
        let (_,m)=try make();var machine=m
        #expect(!(machine.shouldInterceptEscape));#expect((machine.handle(.escape).actions) == ([]))
    }
    @Test func testLessThanHalfSecondOfValidAudioIsDiscarded() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown);clock.now=1;audio(&machine,duration:0.499)
        let result=machine.handle(primaryUp)
        #expect((result.state) == (.cancelled));#expect(result.actions.contains(.feedback(.tooShort)))
        #expect(!(machine.submissionCommitted))
    }
    @Test func testHalfSecondOfValidAudioIsAccepted() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown);clock.now=1;audio(&machine,duration:0.5)
        #expect((machine.handle(primaryUp).state) == (.recognizing))
    }
    @Test func testSilentLockedTimeoutFromLockEntry() throws {
        let (clock,m)=try make();var machine=m;lock(&machine,clock)
        clock.now=10.099;#expect((timer(&machine).state) == (.locked))
        clock.now=10.1;let result=timer(&machine)
        #expect((result.state) == (.cancelled));#expect(result.actions.contains(.feedback(.noSpeech)))
    }
    @Test func testSpeechSilenceEndsAndRecognizesWithoutDropping() throws {
        let (clock,m)=try make();var machine=m;lock(&machine,clock)
        clock.now=8;audio(&machine,duration:0.02)
        clock.now=16;audio(&machine,duration:0.02,speech:false)
        clock.now=27.99;#expect((timer(&machine).state) == (.locked))
        clock.now=28;audio(&machine,duration:0.6,speech:false)
        #expect((timer(&machine).state) == (.recognizing))
    }
    @Test func testConfigurableSilenceTimeout() throws {
        let (clock,m)=try make(Machine.Configuration(lockedSilenceTimeout:3));var machine=m;lock(&machine,clock)
        clock.now=3.1;#expect((timer(&machine).state) == (.cancelled))
    }
    @Test func testMaximumDurationEndsHoldingAndRecognizes() throws {
        let (clock,m)=try make(Machine.Configuration(engineMaximumDuration:2));var machine=m
        machine.handle(primaryDown);clock.now=0.3;_ = timer(&machine);audio(&machine)
        clock.now=2;let result=timer(&machine)
        #expect((result.state) == (.recognizing));#expect(result.actions.contains(.recognize(sessionID:1)))
        #expect(!(machine.shouldInterceptEscape))
    }
    @Test func testMaximumDurationAlsoEndsLocked() throws {
        let (clock,m)=try make(Machine.Configuration(engineMaximumDuration:2));var machine=m;lock(&machine,clock);audio(&machine)
        clock.now=2;#expect((timer(&machine).state) == (.recognizing))
    }
    @Test func testRepeatAndDuplicateDownDoNotStartAgainOrStopLocked() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown)
        #expect((machine.handle(primaryDown).actions) == ([]))
        #expect((machine.handle(.keyDown(binding:.primary,isRepeat:true,standaloneModifier:true)).actions) == ([]))
        clock.advance(0.1);machine.handle(primaryUp)
        #expect((machine.handle(.keyDown(binding:.primary,isRepeat:true,standaloneModifier:true)).state) == (.locked))
    }
    @Test func testKeysAndEscapeIgnoredDuringRecognizingAndInserting() throws {
        let (clock,m)=try make();var machine=m;lock(&machine,clock);audio(&machine);machine.handle(primaryDown)
        for event in [primaryDown,primaryUp,.otherKeyDown,.escape] {
            #expect((machine.handle(event).state) == (.recognizing));#expect((machine.handle(event).actions) == ([]))
        }
        #expect((machine.handle(.recognitionResult(sessionID:1,.text("hello"))).actions) == ([.insertOrCopy(sessionID:1,text:"hello")]))
        for event in [primaryDown,primaryUp,.otherKeyDown,.escape] {#expect((machine.handle(event).state) == (.inserting))}
        #expect((machine.handle(.insertionResult(sessionID:1,.inserted)).state) == (.idle))
    }
    @Test func testClipboardFallbackIsReportedAsCopied() throws {
        let (clock,m)=try make();var machine=m;lock(&machine,clock);audio(&machine);machine.handle(primaryDown)
        machine.handle(.recognitionResult(sessionID:1,.text("hello")))
        let result=machine.handle(.insertionResult(sessionID:1,.copiedToClipboard))
        #expect((result.state) == (.idle));#expect((result.actions) == ([.feedback(.copiedToClipboard)]))
    }
    @Test func testHoldOnlyReleaseEndsRatherThanLocks() throws {
        let (clock,m)=try make(Machine.Configuration(mode:.hold));var machine=m;machine.handle(primaryDown)
        clock.now=1;audio(&machine);#expect((machine.handle(primaryUp).state) == (.recognizing))
    }
    @Test func testTapOnlyLongPressStillLocksInsteadOfHolding() throws {
        let (clock,m)=try make(Machine.Configuration(mode:.toggle));var machine=m;machine.handle(primaryDown)
        clock.now=1;#expect((timer(&machine).state) == (.armed))
        #expect((machine.handle(primaryUp).state) == (.locked))
        audio(&machine);#expect((machine.handle(primaryDown).state) == (.recognizing))
    }
    @Test func testIndependentToggleBindingStillWorksInHybrid() throws {
        let (clock,m)=try make(Machine.Configuration(independentToggleEnabled:true));var machine=m
        let other=Machine.Event.keyDown(binding:.independentToggle,isRepeat:false,standaloneModifier:false)
        machine.handle(other);clock.now=1;#expect((timer(&machine).state) == (.armed))
        #expect((machine.handle(.keyUp(binding:.primary)).state) == (.armed))
        #expect((machine.handle(.keyUp(binding:.independentToggle)).state) == (.locked))
        audio(&machine);#expect((machine.handle(primaryDown).state) == (.recognizing))
    }
    @Test func testDisabledIndependentBindingDoesNothing() throws {
        let (_,m)=try make();var machine=m
        #expect((machine.handle(.keyDown(binding:.independentToggle,isRepeat:false,standaloneModifier:false)).actions) == ([]))
        #expect((machine.state) == (.idle))
    }
    @Test func testUnconsentedCloudNeverStartsCaptureOrCommitsInAnyMode() throws {
        for mode:Machine.Mode in [.hybrid,.hold,.toggle] {
            let (clock,m)=try make(Machine.Configuration(mode:mode,access:.cloud(consented:false)));var machine=m
            var actions=machine.handle(primaryDown).actions;clock.now=1
            actions += timer(&machine).actions;actions += machine.handle(primaryUp).actions
            #expect((machine.state) == (.error));#expect((actions) == ([.feedback(.uploadConsentRequired)]))
            #expect(!(machine.submissionCommitted))
        }
    }
    @Test func testDeniedMicrophoneAndMissingCredentialsHaveSeparateFeedback() throws {
        let (_,m)=try make(Machine.Configuration(microphoneAllowed:false));var mic=m
        #expect((mic.handle(primaryDown).actions) == ([.feedback(.microphoneDenied)]))
        let (_,c)=try make(Machine.Configuration(access:.cloud(consented:true),credentialsAvailable:false));var cloud=c
        #expect((cloud.handle(primaryDown).actions) == ([.feedback(.credentialsMissing)]))
    }
    @Test func testBufferOverflowDiscardsAndRemovesEscapeMonitor() throws {
        let (_,m)=try make();var machine=m;machine.handle(primaryDown)
        let result=machine.handle(.bufferOverflow(sessionID:1))
        #expect((result.state) == (.error));#expect(result.actions.contains(.discardAudio))
        #expect(result.actions.contains(.removeEscapeMonitor));#expect(!(machine.submissionCommitted))
    }
    @Test func testStaleCallbacksCannotAffectNextSession() throws {
        let (clock,m)=try make();var machine=m;machine.handle(primaryDown);machine.handle(.escape)
        machine.handle(primaryUp);machine.handle(primaryDown)
        #expect((machine.sessionID) == (2));clock.now=0.1
        for event:Machine.Event in [.timerFired(sessionID:1),.audioLevel(sessionID:1,validDuration:1,speechDetected:true),
                                   .recognitionResult(sessionID:1,.text("stale")),.captureFailed(sessionID:1),.bufferOverflow(sessionID:1)] {
            #expect((machine.handle(event).actions) == ([]));#expect((machine.state) == (.armed))
        }
        #expect((machine.validAudioDuration) == (0))
    }
    @Test func testCancelledHeldKeyCannotRearmBeforeRelease() throws {
        let (_,m)=try make();var machine=m;machine.handle(primaryDown);machine.handle(.otherKeyDown)
        #expect((machine.handle(primaryDown).state) == (.cancelled))
        machine.handle(primaryUp);#expect((machine.handle(primaryDown).state) == (.armed))
    }
    @Test func testInvalidAudioEventsDoNotExtendDurationOrSilenceDeadline() throws {
        let (clock,m)=try make();var machine=m;lock(&machine,clock)
        for d in [-1,Double.nan,Double.infinity] {audio(&machine,duration:d)}
        #expect((machine.validAudioDuration) == (0))
        clock.now=10.1;#expect((timer(&machine).state) == (.cancelled))
    }
    @Test func testCaptureFailureIsErrorAndCleansUp() throws {
        let (_,m)=try make();var machine=m;machine.handle(primaryDown)
        let result=machine.handle(.captureFailed(sessionID:1))
        #expect((result.state) == (.error));#expect(result.actions.contains(.feedback(.captureFailed)))
        #expect(!(machine.shouldInterceptEscape))
    }
    @Test func testNoTextRecognitionFailureAndInsertionFailure() throws {
        for recognition:Machine.Recognition in [.noText,.text(" \n"),.failed] {
            let (clock,m)=try make();var machine=m;lock(&machine,clock);audio(&machine);machine.handle(primaryDown)
            #expect((machine.handle(.recognitionResult(sessionID:1,recognition)).state) == (.error))
        }
        let (clock,m)=try make();var machine=m;lock(&machine,clock);audio(&machine);machine.handle(primaryDown)
        machine.handle(.recognitionResult(sessionID:1,.text("text")))
        #expect((machine.handle(.insertionResult(sessionID:1,.failed)).actions) == ([.feedback(.insertionFailed)]))
    }
    @Test func testConfigurationBoundsAndFiniteNumbers() throws {
        for t in [0.2,0.3,0.6] {#expect(throws: Never.self) { _ = try Machine.Configuration(longPressThreshold:t) }}
        for t in [0.199,0.601,Double.nan,Double.infinity] {#expect(throws: (any Error).self) { _ = try Machine.Configuration(longPressThreshold:t) }}
        #expect(throws: (any Error).self) { _ = try Machine.Configuration(lockedSilenceTimeout:0) }
        #expect(throws: (any Error).self) { _ = try Machine.Configuration(engineMaximumDuration:0.1) }
        #expect(throws: (any Error).self) { _ = try Machine.Configuration(minimumAudioDuration:0.49) }
        #expect(throws: (any Error).self) { _ = try Machine.Configuration(minimumTapDuration:0.3) }
        #expect(throws: (any Error).self) { _ = try Machine.Configuration(bufferLimitBytes:0) }
    }
    @Test func testWholeRecordingNeverSubmitsAtGateAndCancellationDiscards() throws {
        let (clock,m)=try make(Machine.Configuration(submission:.wholeRecording));var machine=m
        lock(&machine,clock);#expect(!machine.submissionCommitted)
        audio(&machine);let output=machine.handle(.escape)
        #expect(output.state == .cancelled)
        #expect(!output.actions.contains(.uploadWholeRecording(sessionID:1)))
        #expect(!output.actions.contains(.startStreaming(sessionID:1)))
    }
    @Test func testWholeRecordingUploadsOnlyAtValidEnd() throws {
        let (clock,m)=try make(Machine.Configuration(submission:.wholeRecording));var machine=m
        machine.handle(primaryDown);clock.now=0.3
        #expect(timer(&machine).actions.isEmpty);#expect(!machine.submissionCommitted)
        clock.now=1;audio(&machine);let output=machine.handle(primaryUp)
        #expect(output.state == .recognizing)
        #expect(output.actions.contains(.uploadWholeRecording(sessionID:1)))
        #expect(!output.actions.contains(.startStreaming(sessionID:1)))
    }
    @Test func testWholeRecordingTooShortHasNoUpload() throws {
        let (clock,m)=try make(Machine.Configuration(submission:.wholeRecording));var machine=m
        machine.handle(primaryDown);clock.now=0.3;_ = timer(&machine)
        audio(&machine,duration:0.1);clock.now=1
        #expect(machine.handle(primaryUp).state == .cancelled);#expect(!machine.submissionCommitted)
    }
    @Test func testCombinationCanConnectImmediatelyButStandaloneCannot() throws {
        let (_,m)=try make();var machine=m
        #expect(machine.handle(.keyDown(binding:.primary,isRepeat:false,standaloneModifier:false)).actions.contains(.startStreaming(sessionID:1)))
        let (_,n)=try make();var standalone=n
        #expect(!standalone.handle(primaryDown).actions.contains(.startStreaming(sessionID:1)))
    }
    @Test func testPostSpeechTimeoutIsIndependentlyConfigurable() throws {
        let (clock,m)=try make(Machine.Configuration(lockedSilenceTimeout:2,speechSilenceTimeout:5));var machine=m
        lock(&machine,clock);clock.now=1;audio(&machine)
        clock.now=3;#expect(timer(&machine).state == .locked)
        clock.now=6;#expect(timer(&machine).state == .recognizing)
    }
    @Test func testWholeRecordingNoSpeechTimeoutNeverUploads() throws {
        let (clock,m)=try make(Machine.Configuration(submission:.wholeRecording));var machine=m
        lock(&machine,clock);clock.now=10.1
        #expect(timer(&machine).state == .cancelled);#expect(!machine.submissionCommitted)
    }

    @Test func wholeRecordingSilentEndNeverUploads() throws {
        let (clock,m)=try make(try Machine.Configuration(mode:.hold,submission:.wholeRecording));var machine=m
        machine.handle(primaryDown);audio(&machine,duration:1,speech:false);clock.now=1
        let out=machine.handle(primaryUp)
        #expect(out.state == .cancelled)
        #expect(out.actions.contains(.feedback(.noSpeech)))
        #expect(!out.actions.contains(.uploadWholeRecording(sessionID:machine.sessionID)))
    }

}
