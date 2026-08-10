import Observation

@Observable
@MainActor
final class GuideFlowModel {
    static let shared = GuideFlowModel()

    private(set) var state: GuideFlowState

    init(state: GuideFlowState = GuideFlowState()) {
        self.state = state
    }

    var phase: GuidePhase { state.phase }
    var isInteractionLocked: Bool { state.isInteractionLocked }
    var placement: GuidePlacement { state.placement }
    var visibleMissionCount: Int { state.visibleMissionCount }

    func reset() {
        QuestModel.shared.reset()
        state = GuideFlowState()
        AppModel.current?.prepareForGuidePhaseChange(isLocked: true)
    }

    func confirmIntroduction() { apply(.confirmIntroduction) }
    func previousTutorial() { apply(.previousTutorial) }
    func nextTutorial() { apply(.nextTutorial) }
    func skipOnboarding() { apply(.skipOnboarding) }
    func confirmMission() { apply(.confirmMission) }
    func confirmCompletion() { apply(.confirmCompletion) }

    func handleQuestEvent(_ event: QuestEvent) {
        guard case .missionActive = state.phase else { return }
        switch QuestModel.shared.advance(on: event) {
        case .ignored:
            return
        case .advanced(_, let next):
            apply(.questAdvanced(nextIndex: next == nil ? nil : QuestModel.shared.currentIndex))
        }
    }

    func failOpen() {
        let index = min(2, max(0, QuestModel.shared.currentIndex))
        apply(.failOpen(activeMissionIndex: index))
    }

    private func apply(_ action: GuideAction) {
        let wasLocked = state.isInteractionLocked
        state.send(action)
        if wasLocked != state.isInteractionLocked {
            AppModel.current?.prepareForGuidePhaseChange(isLocked: state.isInteractionLocked)
        }
    }
}
