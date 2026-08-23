import Foundation
import Observation

@MainActor
protocol RainbowSmoothiePresenting: AnyObject {
    var isInstalled: Bool { get }
    func revealAtCounter() -> Bool
    func reset()
}

@MainActor
@Observable
final class RainbowSmoothieServingController {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    typealias ReadyHandler = @MainActor @Sendable () -> Void

    private let session: CafeOrderSession
    private let presenter: any RainbowSmoothiePresenting
    private let preparationDelay: Duration
    private let sleep: Sleeper
    private let onReady: ReadyHandler
    private var preparationTask: Task<Void, Never>?
    private(set) var remainingPreparationSeconds: Int = 0

    init(
        session: CafeOrderSession,
        presenter: any RainbowSmoothiePresenting,
        preparationDelay: Duration = .seconds(10),
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        onReady: @escaping ReadyHandler
    ) {
        self.session = session
        self.presenter = presenter
        self.preparationDelay = preparationDelay
        self.sleep = sleep
        self.onReady = onReady
    }

    func enterIndoor() {
        preparationTask?.cancel()
        preparationTask = nil
        remainingPreparationSeconds = 0
        let generation = session.beginIndoorSession()
        if !presenter.isInstalled {
            session.markFailed(generation: generation)
        }
    }

    func acceptOrder() {
        guard presenter.isInstalled,
              let generation = session.acceptOrder() else { return }
        preparationTask?.cancel()
        let totalSeconds = Int(preparationDelay.components.seconds)
        remainingPreparationSeconds = max(1, totalSeconds)
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if totalSeconds > 1 {
                for remaining in stride(from: totalSeconds, through: 1, by: -1) {
                    self.remainingPreparationSeconds = remaining
                    do {
                        try await self.sleep(.seconds(1))
                    } catch {
                        self.remainingPreparationSeconds = 0
                        return
                    }
                    guard !Task.isCancelled,
                          generation == self.session.generation else {
                        self.remainingPreparationSeconds = 0
                        return
                    }
                }
            } else {
                do {
                    try await self.sleep(self.preparationDelay)
                } catch {
                    self.remainingPreparationSeconds = 0
                    return
                }
            }
            self.remainingPreparationSeconds = 0
            guard !Task.isCancelled,
                  generation == self.session.generation else { return }
            guard self.presenter.revealAtCounter() else {
                self.session.markFailed(generation: generation)
                self.preparationTask = nil
                return
            }
            guard self.session.markReady(generation: generation) else { return }
            self.preparationTask = nil
            self.onReady()
        }
    }

    func resetForOutdoor() {
        preparationTask?.cancel()
        preparationTask = nil
        remainingPreparationSeconds = 0
        presenter.reset()
        session.resetForOutdoor()
    }
}
