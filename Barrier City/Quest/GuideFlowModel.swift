import Observation
import OSLog

@Observable
@MainActor
final class GuideFlowModel {
    static let shared = GuideFlowModel()
    private static let logger = Logger(
        subsystem: "com.Television.Barrier-City",
        category: "QuestFlow"
    )

    private(set) var state: GuideFlowState

    init(state: GuideFlowState = GuideFlowState()) {
        self.state = state
    }

    var phase: GuidePhase { state.phase }
    var isInteractionLocked: Bool { state.isInteractionLocked }
    var placement: GuidePlacement { state.placement }
    var visibleMissionCount: Int { state.visibleMissionCount }
    var allowsNPCConversation: Bool { state.allowsNPCConversation }
    var allowsNPCOrderConversation: Bool { state.allowsNPCOrderConversation }

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
        let previousPhase = state.phase
        let previousIndex = QuestModel.shared.currentIndex
        let acceptsQuestEvent: Bool
        switch state.phase {
        case .missionActive, .postOrderPending:
            acceptsQuestEvent = true
        default:
            acceptsQuestEvent = false
        }
        guard acceptsQuestEvent else {
#if DEBUG
            Self.logger.debug(
                "[QUEST_FLOW] ignored event=\(String(describing: event), privacy: .public) phase=\(String(describing: previousPhase), privacy: .public) questIndex=\(previousIndex, privacy: .public)"
            )
#endif
            return
        }
        switch QuestModel.shared.advance(on: event) {
        case .ignored:
#if DEBUG
            Self.logger.debug(
                "[QUEST_FLOW] ignored event=\(String(describing: event), privacy: .public) phase=\(String(describing: previousPhase), privacy: .public) questIndex=\(previousIndex, privacy: .public)"
            )
#endif
            return
        case .advanced(_, let next):
            apply(.questAdvanced(nextIndex: next == nil ? nil : QuestModel.shared.currentIndex))
#if DEBUG
            Self.logger.notice(
                "[QUEST_FLOW] advanced event=\(String(describing: event), privacy: .public) phase=\(String(describing: previousPhase), privacy: .public)->\(String(describing: self.state.phase), privacy: .public) questIndex=\(previousIndex, privacy: .public)->\(QuestModel.shared.currentIndex, privacy: .public)"
            )
#endif
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
