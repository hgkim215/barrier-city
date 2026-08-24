import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
struct ExperienceCompletionStateTests {
    static func main() {
        let clock = ContinuousClock()
        let start = clock.now

        var timer = ExperienceRunTimer()
        expect(timer.formattedElapsed, "00:00", "an unstarted run displays zero time")

        timer.start(at: start)
        expect(timer.isRunning, true, "starting a run begins timing")
        expect(timer.finish(at: start.advanced(by: .seconds(1_728))), true,
               "the first mission completion freezes the timer")
        expect(timer.formattedElapsed, "28:48",
               "the frozen duration uses the Ending design's MM:SS format")

        expect(timer.finish(at: start.advanced(by: .seconds(3_900))), false,
               "duplicate completion cannot overwrite the first result")
        expect(timer.formattedElapsed, "28:48",
               "duplicate completion preserves the original elapsed time")

        timer.reset()
        expect(timer.isRunning, false, "reset stops timing")
        expect(timer.formattedElapsed, "00:00", "reset clears elapsed time")

        timer.start(at: start)
        _ = timer.finish(at: start.advanced(by: .seconds(4_503)))
        expect(timer.formattedElapsed, "75:03",
               "runs longer than one hour retain total minutes")

        var celebration = ExperienceCelebrationState()
        let firstGeneration = celebration.begin()
        expect(firstGeneration, 1, "the first ending starts one celebration")
        expect(celebration.isPlaying, true,
               "the celebration remains active while the ending popup is visible")
        expect(celebration.begin(), nil, "an active celebration rejects duplicate starts")
        expect(celebration.isPlaying, true,
               "duplicate completion cannot stop the active celebration")
        expect(celebration.stop(), true,
               "confirming the ending explicitly stops the celebration")
        expect(celebration.isPlaying, false, "stopping ends particle playback")
        expect(celebration.stop(), false,
               "a duplicate stop cannot mutate playback twice")

        celebration.reset()
        expect(celebration.begin(), 2, "a reset session can celebrate again")

        print("ExperienceCompletionStateTests: PASS")
    }
}
