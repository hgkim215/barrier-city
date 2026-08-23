import Foundation

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@MainActor
private final class PresentationRecorder {
    var presentCount = 0
    var speakCount = 0
    var didComplete = false

    private var presentationWaiters: [CheckedContinuation<Void, Never>] = []

    func present() {
        presentCount += 1
        let waiters = presentationWaiters
        presentationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilPresented() async {
        guard presentCount == 0 else { return }
        await withCheckedContinuation { continuation in
            presentationWaiters.append(continuation)
        }
    }
}

private actor ControlledMinimumWait {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async throws {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@main
struct OrderReadyAnnouncementPresentationTests {
    @MainActor
    static func main() async {
        expect(
            OrderReadyAnnouncementContent.line
                == "주문하신 레인보우 스무디 나왔습니다. 카운터에서 가져가 주세요.",
            "ready announcement must preserve the exact accepted subtitle"
        )

        let idle = OrderReadyAnnouncementPresentationState(
            hasPendingAnnouncement: false,
            hasActiveTask: false
        )
        expect(!idle.isPresented, "idle state must not present the ready announcement")
        expect(
            idle.interactionAttachmentIsVisible(
                isNormallyVisible: true,
                isGuideLocked: false,
                allowsConversation: true
            ),
            "ordinary unlocked conversation must keep its interaction attachment"
        )
        expect(
            idle.showsTalkButton(isEncounterActive: false, clerkPhaseAllowsButton: true),
            "idle state must preserve the ordinary talk button"
        )

        let pending = OrderReadyAnnouncementPresentationState(
            hasPendingAnnouncement: true,
            hasActiveTask: false
        )
        expect(pending.isPresented, "queued ready announcement must count as presented")
        expect(
            pending.interactionAttachmentIsVisible(
                isNormallyVisible: true,
                isGuideLocked: true,
                allowsConversation: false
            ),
            "queued ready announcement must override guide/conversation locking"
        )
        expect(
            !pending.showsTalkButton(isEncounterActive: false, clerkPhaseAllowsButton: true),
            "queued ready announcement must suppress the talk button"
        )

        let active = OrderReadyAnnouncementPresentationState(
            hasPendingAnnouncement: false,
            hasActiveTask: true
        )
        expect(active.isPresented, "active ready announcement must count as presented")
        expect(
            active.interactionAttachmentIsVisible(
                isNormallyVisible: true,
                isGuideLocked: false,
                allowsConversation: false
            ),
            "active ready announcement must remain visible after order conversation closes"
        )
        expect(
            !active.interactionAttachmentIsVisible(
                isNormallyVisible: false,
                isGuideLocked: false,
                allowsConversation: false
            ),
            "ready announcement must not revive an explicitly hidden NPC attachment"
        )
        expect(
            !active.showsTalkButton(isEncounterActive: false, clerkPhaseAllowsButton: true),
            "active ready announcement must render subtitle instead of talk button"
        )

        let controlledWait = ControlledMinimumWait()
        let recorder = PresentationRecorder()
        let presentationTask = Task { @MainActor in
            let didComplete = await OrderReadyAnnouncementPresentationTiming.perform(
                present: { recorder.present() },
                speak: { recorder.speakCount += 1 },
                waitForMinimumVisibility: { try await controlledWait.wait() }
            )
            recorder.didComplete = didComplete
            return didComplete
        }

        await controlledWait.waitUntilEntered()
        expect(recorder.presentCount == 1, "subtitle must be presented before the minimum wait")
        expect(!recorder.didComplete, "immediate speech must not end presentation before minimum wait")
        await controlledWait.release()
        let presentationDidComplete = await presentationTask.value
        expect(presentationDidComplete, "presentation must complete after speech and minimum wait")
        expect(recorder.speakCount == 1, "ready announcement must speak exactly once")

        let cancellationRecorder = PresentationRecorder()
        let cancellationTask = Task { @MainActor in
            await OrderReadyAnnouncementPresentationTiming.perform(
                present: { cancellationRecorder.present() },
                speak: { cancellationRecorder.speakCount += 1 },
                waitForMinimumVisibility: { try await Task.sleep(for: .seconds(60)) }
            )
        }

        await cancellationRecorder.waitUntilPresented()
        cancellationTask.cancel()
        let cancellationDidComplete = await cancellationTask.value
        expect(
            !cancellationDidComplete,
            "cancellation must prevent normal ready-announcement completion"
        )

        print("Order ready announcement presentation contract passed.")
    }
}
