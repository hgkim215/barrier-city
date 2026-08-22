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
        enum PresentationStatus {
            case idle
            case speaking
        }

        let coordinator = RealtimeFailureOrderConfirmationCoordinator()
        let speech = ControlledConfirmationSpeech()
        var subtitle = ""
        var status = PresentationStatus.idle
        var publishCount = 0
        var finishCount = 0
        var cancellationCleanupCount = 0

        let present: RealtimeFailureOrderConfirmationCoordinator.Presenter = { line in
            subtitle = line
            status = .speaking
        }
        let cancellationCleanup: RealtimeFailureOrderConfirmationCoordinator.Handler = {
            subtitle = ""
            status = .idle
            cancellationCleanupCount += 1
        }
        let finish: RealtimeFailureOrderConfirmationCoordinator.Handler = {
            status = .idle
            finishCount += 1
        }

        let firstGeneration = coordinator.beginEncounter()
        let firstTask = coordinator.recoverCompletedOrder(
            encounterGeneration: firstGeneration,
            present: present,
            speak: { await speech.speak($0) },
            publish: { publishCount += 1 },
            finish: finish,
            cancel: cancellationCleanup)
        expect(firstTask != nil, "completed order failure starts one local confirmation")
        expect(subtitle == "레인보우 스무디 한 잔 주문됐어요. 준비되면 알려드릴게요.",
               "failure confirmation exposes the exact subtitle immediately")
        expect(status == .speaking, "local confirmation presents a speaking lifecycle")
        await speech.waitUntilEntered(1)
        expect(publishCount == 0, "order event waits for confirmation speech completion")
        expect(finishCount == 0, "recovery remains active while speech is playing")

        let duplicateTask = coordinator.recoverCompletedOrder(
            encounterGeneration: firstGeneration,
            present: { _ in fatalError("FAIL: duplicate recovery must not present") },
            speak: { _ in fatalError("FAIL: duplicate recovery must not speak") },
            publish: { publishCount += 1 },
            finish: finish,
            cancel: cancellationCleanup)
        expect(duplicateTask == nil, "same encounter cannot recover twice")

        await speech.finish(1)
        await firstTask?.value
        expect(publishCount == 1, "order event publishes once after speech completes")
        expect(finishCount == 1, "successful recovery finishes once")
        expect(status == .idle, "successful recovery restores idle")
        expect(cancellationCleanupCount == 0, "normal completion does not run cancellation cleanup")

        let cancelledGeneration = coordinator.beginEncounter()
        let cancelledTask = coordinator.recoverCompletedOrder(
            encounterGeneration: cancelledGeneration,
            present: present,
            speak: { await speech.speak($0) },
            publish: { publishCount += 1 },
            finish: finish,
            cancel: cancellationCleanup)
        await speech.waitUntilEntered(2)
        expect(status == .speaking, "recovery is speaking before departure cancellation")
        coordinator.cancel()
        expect(status == .idle, "cancelling active recovery immediately restores idle")
        expect(subtitle.isEmpty, "cancelling active recovery clears its subtitle")
        expect(cancellationCleanupCount == 1, "active recovery cancellation cleans up exactly once")
        await speech.finish(2)
        await cancelledTask?.value
        expect(publishCount == 1, "cancelled recovery cannot publish after speech returns")
        expect(finishCount == 1, "cancelled recovery cannot finish normally")

        let resumedGeneration = coordinator.beginEncounter()
        let resumedTask = coordinator.recoverCompletedOrder(
            encounterGeneration: resumedGeneration,
            present: present,
            speak: { await speech.speak($0) },
            publish: { publishCount += 1 },
            finish: finish,
            cancel: cancellationCleanup)
        await speech.waitUntilEntered(3)
        expect(status == .speaking, "a subsequent recovery can start after cancellation")
        await speech.finish(3)
        await resumedTask?.value
        expect(publishCount == 2, "subsequent recovery publishes after its own speech")
        expect(finishCount == 2, "subsequent recovery completes normally")
        expect(status == .idle, "subsequent recovery returns to idle")

        let staleGeneration = coordinator.beginEncounter()
        let staleTask = coordinator.recoverCompletedOrder(
            encounterGeneration: staleGeneration,
            present: present,
            speak: { await speech.speak($0) },
            publish: { publishCount += 1 },
            finish: finish,
            cancel: cancellationCleanup)
        await speech.waitUntilEntered(4)
        let freshGeneration = coordinator.beginEncounter()
        expect(status == .idle, "fresh encounter cleans up the stale recovery presentation")
        await speech.finish(4)
        await staleTask?.value
        expect(publishCount == 2, "stale encounter cannot publish into a fresh encounter")

        let freshTask = coordinator.recoverCompletedOrder(
            encounterGeneration: freshGeneration,
            present: present,
            speak: { await speech.speak($0) },
            publish: { publishCount += 1 },
            finish: finish,
            cancel: cancellationCleanup)
        await speech.waitUntilEntered(5)
        expect(publishCount == 2, "fresh recovery still waits for its own speech")
        await speech.finish(5)
        await freshTask?.value
        expect(publishCount == 3, "fresh encounter publishes exactly once after confirmation")
        expect(finishCount == 3, "only completed current recoveries finish")
        expect(cancellationCleanupCount == 2,
               "only explicit cancellation and stale rollover clean active presentation")

        print("PASS: RealtimeFailureOrderConfirmationCoordinatorTests")
    }
}
