import Testing
@testable import LitteroiWatch

@Test func startsACallOnceACallAppHasHeldTheMicForThreePolls() {
    var detector = CallDetector()
    let teams: Set = ["com.microsoft.teams2", "com.apple.Terminal"]
    #expect(detector.update(micUsers: teams) == nil)
    #expect(detector.update(micUsers: teams) == nil)
    #expect(detector.update(micUsers: teams) == .started(app: "Teams", litteroiRecording: false))
    #expect(detector.update(micUsers: teams) == nil)
    #expect(detector.call == "Teams")
}

@Test func ignoresAppsThatAreNotForCalls() {
    var detector = CallDetector(startPolls: 1)
    #expect(detector.update(micUsers: ["com.apple.VoiceMemos", "com.apple.CoreSpeech"]) == nil)
    #expect(detector.call == nil)
}

@Test func endsACallOnlyAfterTheMicHasBeenFreeForFifteenPolls() {
    var detector = CallDetector(startPolls: 1)
    #expect(detector.update(micUsers: ["com.google.Chrome.helper"]) == .started(app: "Chrome", litteroiRecording: false))
    #expect(detector.update(micUsers: []) == .quiet)
    for _ in 2..<15 {
        #expect(detector.update(micUsers: []) == nil)
    }
    #expect(detector.update(micUsers: ["com.google.Chrome.helper"]) == .resumed)
    #expect(detector.update(micUsers: []) == .quiet)
    for _ in 2..<15 {
        #expect(detector.update(micUsers: []) == nil)
    }
    #expect(detector.update(micUsers: []) == .ended)
    #expect(detector.call == nil)
}

@Test func makesACallQuietOnceTheMicHasBeenFreeForThreePolls() {
    var detector = CallDetector(startPolls: 3)
    let signal: Set = ["org.whispersystems.signal-desktop"]
    for _ in 1...3 {
        _ = detector.update(micUsers: signal)
    }
    #expect(detector.update(micUsers: []) == nil)
    #expect(detector.update(micUsers: signal) == nil)
    #expect(detector.update(micUsers: []) == nil)
    #expect(detector.update(micUsers: []) == nil)
    #expect(detector.update(micUsers: []) == .quiet)
    #expect(detector.update(micUsers: []) == nil)
    #expect(detector.call == "Signal")
}

@Test func saysWhenLitteroiIsAlreadyRecording() {
    var detector = CallDetector(startPolls: 1)
    #expect(detector.update(micUsers: ["com.tinyspeck.slackmacgap.helper", "fi.taitounited.litteroi"])
        == .started(app: "Slack", litteroiRecording: true))
}
