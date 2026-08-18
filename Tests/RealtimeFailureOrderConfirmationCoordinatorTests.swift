import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private actor ControlledConfirmationSpeech {
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var enteredCalls: Set<Int> = []
    private var enteredWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextCall = 0

    func speak(_ line: String) async {
        guard line == RealtimeFailureOrderConfirmationContent.line else {
            fatalError("FAIL: confirmation speech must use the exact accepted line")
        }
        nextCall += 1
        let call = nextCall
        enteredCalls.insert(call)
        enteredWaiters.removeValue(forKey: call)?.resume()
        await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func waitUntilEntered(_ call: Int) async {
        if enteredCalls.contains(call) { return }
        await withCheckedContinuation { continuation in
            enteredWaiters[call] = continuation
        }
    }

    func finish(_ call: Int) {
        guard let continuation = continuations.removeValue(forKey: call) else {
            fatalError("FAIL: speech call \(call) must be active before finish")
        }
        continuation.resume()
    }
}

@main
@MainActor
struct RealtimeFailureOrderConfirmationCoordinatorTests {
    static func main() async {
        let coordinator = RealtimeFailureOrderConfirmationCoordinator()
        let speech = ControlledConfirmationSpeech()
        var subtitle = ""
        var publishCount = 0
        var finishCount = 0

        let firstGeneration = coordinator.beginEncounter()
        let firstTask = coordinator.recoverCompletedOrder(
            encounterGeneration: firstGeneration,
            present: { subtitle = $0 },
            speak: { await speech.speak($0) },
            publish: { publishCount += 1 },
            finish: { finishCount += 1 })
        expect(firstTask != nil, "completed order failure starts one local confirmation")
        expect(subtitle == "레인보우 스무디 한 잔 주문됐어요. 준비되면 알려드릴게요.",
               "failure confirmation exposes the exact subtitle immediately")
        await speech.waitUntilEntered(1)
        expect(publishCount == 0, "order event waits for confirmation speech completion")
        expect(finishCount == 0, "recovery remains active while speech is playing")

        let duplicateTask = coordinator.recoverCompletedOrder(
            encounterGeneration: firstGeneration,
            present: { _ in fatalError("FAIL: duplicate recovery must not present") },
            speak: { _ in fatalError("FAIL: duplicate recovery must not speak") },
            publish: { publishCount += 1 },
            finish: { finishCount += 1 })
        expect(duplicateTask == nil, "same encounter cannot recover twice")

        await speech.finish(1)
        await firstTask?.value
        expect(publishCount == 1, "order event publishes once after speech completes")
        expect(finishCount == 1, "successful recovery finishes once")

        let cancelledGeneration = coordinator.beginEncounter()
        let cancelledTask = coordinator.recoverCompletedOrder(
            encounterGeneration: cancelledGeneration,
            present: { subtitle = $0 },
            speak: { await speech.speak($0) },
            publish: { publishCount += 1 },
            finish: { finishCount += 1 })
        await speech.waitUntilEntered(2)
        coordinator.cancel()
        await speech.finish(2)
        await cancelledTask?.value
        expect(publishCount == 1, "cancelled recovery cannot publish after speech returns")
        expect(finishCount == 1, "cancelled recovery cannot finish normally")

        let staleGeneration = coordinator.beginEncounter()
        let staleTask = coordinator.recoverCompletedOrder(
            encounterGeneration: staleGeneration,
            present: { subtitle = $0 },
            speak: { await speech.speak($0) },
            publish: { publishCount += 1 },
            finish: { finishCount += 1 })
        await speech.waitUntilEntered(3)
        let freshGeneration = coordinator.beginEncounter()
        await speech.finish(3)
        await staleTask?.value
        expect(publishCount == 1, "stale encounter cannot publish into a fresh encounter")

        let freshTask = coordinator.recoverCompletedOrder(
            encounterGeneration: freshGeneration,
            present: { subtitle = $0 },
            speak: { await speech.speak($0) },
            publish: { publishCount += 1 },
            finish: { finishCount += 1 })
        await speech.waitUntilEntered(4)
        expect(publishCount == 1, "fresh recovery still waits for its own speech")
        await speech.finish(4)
        await freshTask?.value
        expect(publishCount == 2, "fresh encounter publishes exactly once after confirmation")
        expect(finishCount == 2, "only completed current recoveries finish")

        print("PASS: RealtimeFailureOrderConfirmationCoordinatorTests")
    }
}
