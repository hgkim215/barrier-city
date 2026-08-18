import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

@MainActor
private final class PresenterSpy: RainbowSmoothiePresenting {
    var isInstalled = true
    var revealResult = true
    var revealCount = 0
    var resetCount = 0
    var afterReveal: (@MainActor () -> Void)?

    func revealAtCounter() -> Bool {
        revealCount += 1
        afterReveal?()
        return revealResult
    }

    func reset() {
        resetCount += 1
        isInstalled = false
    }
}

private actor DelayRecorder {
    private(set) var received: Duration?
    private var receivedContinuation: CheckedContinuation<Duration, Never>?

    func sleep(for duration: Duration) {
        received = duration
        receivedContinuation?.resume(returning: duration)
        receivedContinuation = nil
    }

    func waitForReceived() async -> Duration {
        if let received {
            return received
        }
        return await withCheckedContinuation { continuation in
            receivedContinuation = continuation
        }
    }
}

private actor ControllerStateRecorder {
    private var state: CafeOrderPhase?
    private var stateContinuation: CheckedContinuation<CafeOrderPhase, Never>?

    func record(_ state: CafeOrderPhase) {
        guard self.state == nil else { return }
        self.state = state
        stateContinuation?.resume(returning: state)
        stateContinuation = nil
    }

    func waitForState() async -> CafeOrderPhase {
        if let state {
            return state
        }
        return await withCheckedContinuation { continuation in
            stateContinuation = continuation
        }
    }
}

private actor ControlledSleeper {
    private var continuation: CheckedContinuation<Void, Never>?
    private var sleepEntered = false
    private var sleepEnteredContinuation: CheckedContinuation<Void, Never>?
    private var sleepReturned = false
    private var sleepReturnedAfterCancellation = false
    private var sleepReturnedContinuation: CheckedContinuation<Bool, Never>?

    func sleep() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            sleepEntered = true
            sleepEnteredContinuation?.resume()
            sleepEnteredContinuation = nil
        }
        sleepReturned = true
        sleepReturnedAfterCancellation = Task.isCancelled
        sleepReturnedContinuation?.resume(returning: sleepReturnedAfterCancellation)
        sleepReturnedContinuation = nil
    }

    func waitUntilSleepEntered() async {
        if sleepEntered {
            return
        }
        await withCheckedContinuation { continuation in
            sleepEnteredContinuation = continuation
        }
    }

    func waitUntilSleepReturned() async -> Bool {
        if sleepReturned {
            return sleepReturnedAfterCancellation
        }
        return await withCheckedContinuation { continuation in
            sleepReturnedContinuation = continuation
        }
    }

    func finish() {
        guard let continuation else {
            fatalError("FAIL: sleep must be entered before finish")
        }
        self.continuation = nil
        continuation.resume()
    }
}

private actor ReentrySleeper {
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var enteredCalls: Set<Int> = []
    private var enteredWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextCall = 0

    func sleep() async {
        nextCall += 1
        let call = nextCall
        enteredCalls.insert(call)
        enteredWaiters.removeValue(forKey: call)?.resume()
        await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func waitUntilEntered(_ call: Int) async {
        if enteredCalls.contains(call) {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiters[call] = continuation
        }
    }

    func finish(_ call: Int) {
        guard let continuation = continuations.removeValue(forKey: call) else {
            fatalError("FAIL: sleep call \(call) must be entered before finish")
        }
        continuation.resume()
    }
}

@main
@MainActor
struct RainbowSmoothieServingControllerTests {
    static func main() async {
        let session = CafeOrderSession()
        let presenter = PresenterSpy()
        let delayRecorder = DelayRecorder()
        let readyStateRecorder = ControllerStateRecorder()
        var readyCount = 0
        let controller = RainbowSmoothieServingController(
            session: session,
            presenter: presenter,
            preparationDelay: .seconds(10),
            sleep: { await delayRecorder.sleep(for: $0) },
            onReady: {
                readyCount += 1
                Task { @MainActor in
                    await readyStateRecorder.record(session.phase)
                }
            })

        controller.enterIndoor()
        controller.acceptOrder()
        controller.acceptOrder()
        let recordedDelay = await delayRecorder.waitForReceived()
        expect(recordedDelay == .seconds(10), "controller requests ten seconds")
        let readyState = await readyStateRecorder.waitForState()
        expect(readyState == .readyAtCounter, "successful delay completes in the ready state")
        expect(session.phase == .readyAtCounter, "successful delay becomes ready")
        expect(presenter.revealCount == 1, "duplicate order reveals one entity")
        expect(readyCount == 1, "ready callback fires once")

        presenter.isInstalled = true
        presenter.revealResult = false
        let failedStateRecorder = ControllerStateRecorder()
        presenter.afterReveal = {
            Task { @MainActor in
                await failedStateRecorder.record(session.phase)
            }
        }
        controller.enterIndoor()
        controller.acceptOrder()
        let failedState = await failedStateRecorder.waitForState()
        expect(failedState == .failed, "failed reveal completes in the failed state")
        expect(session.phase == .failed, "presenter failure is explicit")
        expect(readyCount == 1, "failed reveal has no ready callback")

        presenter.isInstalled = false
        controller.enterIndoor()
        expect(session.phase == .failed, "missing installation fails before ordering")

        controller.resetForOutdoor()
        expect(session.phase == .notOrdered, "reset restores order state")
        expect(presenter.resetCount == 1, "reset tears down presenter")

        let cancellationSession = CafeOrderSession()
        let cancellationPresenter = PresenterSpy()
        let controlledSleeper = ControlledSleeper()
        var cancelledReadyCount = 0
        let cancellable = RainbowSmoothieServingController(
            session: cancellationSession,
            presenter: cancellationPresenter,
            sleep: { _ in await controlledSleeper.sleep() },
            onReady: { cancelledReadyCount += 1 })
        cancellable.enterIndoor()
        cancellable.acceptOrder()
        await controlledSleeper.waitUntilSleepEntered()
        cancellable.resetForOutdoor()
        await controlledSleeper.finish()
        let sleepReturnedAfterCancellation = await controlledSleeper.waitUntilSleepReturned()
        expect(sleepReturnedAfterCancellation, "reset cancels pending work")
        expect(cancellationPresenter.revealCount == 0, "cancelled delay cannot reveal")
        expect(cancelledReadyCount == 0, "cancelled delay cannot announce")
        expect(cancellationSession.phase == .notOrdered, "cancelled delay cannot mutate reset session")

        let reentrySession = CafeOrderSession()
        let reentryPresenter = PresenterSpy()
        let reentrySleeper = ReentrySleeper()
        let reentryReadyStateRecorder = ControllerStateRecorder()
        var reentryReadyCount = 0
        let reentryController = RainbowSmoothieServingController(
            session: reentrySession,
            presenter: reentryPresenter,
            sleep: { _ in await reentrySleeper.sleep() },
            onReady: {
                reentryReadyCount += 1
                Task { @MainActor in
                    await reentryReadyStateRecorder.record(reentrySession.phase)
                }
            })

        reentryController.enterIndoor()
        reentryController.acceptOrder()
        await reentrySleeper.waitUntilEntered(1)
        reentryController.resetForOutdoor()

        reentryPresenter.isInstalled = true
        reentryController.enterIndoor()
        reentryController.acceptOrder()
        await reentrySleeper.waitUntilEntered(2)

        await reentrySleeper.finish(1)
        await Task.yield()
        expect(reentryPresenter.revealCount == 0, "stale sleeper cannot reveal in a fresh session")
        expect(reentryReadyCount == 0, "stale sleeper cannot announce in a fresh session")
        expect(reentrySession.phase == .preparing, "stale sleeper cannot mutate the new preparation")

        await reentrySleeper.finish(2)
        let reentryReadyState = await reentryReadyStateRecorder.waitForState()
        expect(reentryReadyState == .readyAtCounter, "fresh sleeper completes the new session")
        expect(reentryPresenter.revealCount == 1, "fresh session reveals exactly once")
        expect(reentryReadyCount == 1, "fresh session announces exactly once")
        print("PASS: RainbowSmoothieServingControllerTests")
    }
}
