import Foundation

enum RealtimeFailureOrderConfirmationContent {
    static let line = "레인보우 스무디 한 잔 주문됐어요. 준비되면 알려드릴게요."
}

@MainActor
final class RealtimeFailureOrderConfirmationCoordinator {
    typealias Presenter = @MainActor @Sendable (String) -> Void
    typealias Speaker = @MainActor @Sendable (String) async -> Void
    typealias Handler = @MainActor @Sendable () -> Void

    private var generation = 0
    private var didHandleCurrentEncounter = false
    private var confirmationTask: Task<Void, Never>?

    @discardableResult
    func beginEncounter() -> Int {
        confirmationTask?.cancel()
        confirmationTask = nil
        generation &+= 1
        didHandleCurrentEncounter = false
        return generation
    }

    @discardableResult
    func recoverCompletedOrder(
        encounterGeneration: Int,
        present: @escaping Presenter,
        speak: @escaping Speaker,
        publish: @escaping Handler,
        finish: @escaping Handler
    ) -> Task<Void, Never>? {
        guard encounterGeneration == generation,
              !didHandleCurrentEncounter,
              confirmationTask == nil else { return nil }

        didHandleCurrentEncounter = true
        present(RealtimeFailureOrderConfirmationContent.line)
        let task = Task { @MainActor [weak self] in
            await speak(RealtimeFailureOrderConfirmationContent.line)
            guard let self,
                  !Task.isCancelled,
                  encounterGeneration == self.generation else { return }
            self.confirmationTask = nil
            publish()
            finish()
        }
        confirmationTask = task
        return task
    }

    func cancel() {
        confirmationTask?.cancel()
        confirmationTask = nil
        generation &+= 1
        didHandleCurrentEncounter = true
    }
}
