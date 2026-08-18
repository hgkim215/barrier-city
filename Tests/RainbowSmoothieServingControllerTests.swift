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

    func revealAtCounter() -> Bool {
        revealCount += 1
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

private actor ControlledSleeper {
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@main
@MainActor
struct RainbowSmoothieServingControllerTests {
    static func main() async {
        let session = CafeOrderSession()
        let presenter = PresenterSpy()
        let delayRecorder = DelayRecorder()
        var readyCount = 0
        let controller = RainbowSmoothieServingController(
            session: session,
            presenter: presenter,
            preparationDelay: .seconds(10),
            sleep: { await delayRecorder.sleep(for: $0) },
            onReady: { readyCount += 1 })

        controller.enterIndoor()
        controller.acceptOrder()
        controller.acceptOrder()
        let recordedDelay = await delayRecorder.waitForReceived()
        expect(recordedDelay == .seconds(10), "controller requests ten seconds")
        expect(session.phase == .readyAtCounter, "successful delay becomes ready")
        expect(presenter.revealCount == 1, "duplicate order reveals one entity")
        expect(readyCount == 1, "ready callback fires once")

        presenter.isInstalled = true
        presenter.revealResult = false
        controller.enterIndoor()
        controller.acceptOrder()
        await Task.yield()
        await Task.yield()
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
        await Task.yield()
        cancellable.resetForOutdoor()
        await controlledSleeper.finish()
        await Task.yield()
        expect(cancellationPresenter.revealCount == 0, "cancelled delay cannot reveal")
        expect(cancelledReadyCount == 0, "cancelled delay cannot announce")
        expect(cancellationSession.phase == .notOrdered, "cancelled delay cannot mutate reset session")
        print("PASS: RainbowSmoothieServingControllerTests")
    }
}
