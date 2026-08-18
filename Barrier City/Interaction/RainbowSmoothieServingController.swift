import Foundation

@MainActor
protocol RainbowSmoothiePresenting: AnyObject {
    var isInstalled: Bool { get }
    func revealAtCounter() -> Bool
    func reset()
}

@MainActor
final class RainbowSmoothieServingController {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    typealias ReadyHandler = @MainActor @Sendable () -> Void

    private let session: CafeOrderSession
    private let presenter: any RainbowSmoothiePresenting
    private let preparationDelay: Duration
    private let sleep: Sleeper
    private let onReady: ReadyHandler
    private var preparationTask: Task<Void, Never>?

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
        let generation = session.beginIndoorSession()
        if !presenter.isInstalled {
            session.markFailed(generation: generation)
        }
    }

    func acceptOrder() {
        guard presenter.isInstalled,
              let generation = session.acceptOrder() else { return }
        preparationTask?.cancel()
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(self.preparationDelay)
            } catch {
                return
            }
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
        presenter.reset()
        session.resetForOutdoor()
    }
}
