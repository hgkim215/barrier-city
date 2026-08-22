import Foundation

enum GuidePhase: Equatable {
    case introduction
    case tutorial(index: Int)
    case missionAnnouncement(index: Int)
    case missionActive(index: Int)
    /// 음료 준비·수령·착석 UI가 구현되기 전까지 화면 없이 유지하는 후속 진행 상태.
    case postOrderPending(index: Int)
    case completionAnnouncement
    case completed
}

enum GuidePlacement: Equatable {
    case centerModal
    case upperLeadingHUD
}

enum GuideAction: Equatable {
    case confirmIntroduction
    case previousTutorial
    case nextTutorial
    case skipOnboarding
    case confirmMission
    case questAdvanced(nextIndex: Int?)
    case confirmCompletion
    case failOpen(activeMissionIndex: Int)
}

struct GuideFlowState: Equatable {
    private(set) var phase: GuidePhase

    init(phase: GuidePhase = .introduction) {
        self.phase = phase
    }

    var isInteractionLocked: Bool {
        switch phase {
        case .missionActive, .postOrderPending, .completed: false
        case .introduction, .tutorial, .missionAnnouncement, .completionAnnouncement: true
        }
    }

    var placement: GuidePlacement {
        switch phase {
        case .missionActive, .postOrderPending, .completed: .upperLeadingHUD
        default: .centerModal
        }
    }

    var visibleMissionCount: Int {
        switch phase {
        case .missionAnnouncement(let index), .missionActive(let index): index + 1
        case .postOrderPending(let index): index + 1
        case .completionAnnouncement, .completed: 6
        case .introduction, .tutorial: 0
        }
    }

    /// 주문 후 준비·수령 상태 질문은 같은 공간의 점원에게 계속 할 수 있다.
    var allowsNPCConversation: Bool {
        switch phase {
        case .missionActive(index: 2), .postOrderPending:
            true
        default:
            false
        }
    }

    /// 새 주문 접수는 세 번째 미션이 실제 활성화된 동안에만 가능하다.
    var allowsNPCOrderConversation: Bool {
        phase == .missionActive(index: 2)
    }

    mutating func send(_ action: GuideAction) {
        switch (phase, action) {
        case (.introduction, .confirmIntroduction):
            phase = .tutorial(index: 0)
        case (.introduction, .skipOnboarding), (.tutorial, .skipOnboarding):
            phase = .missionAnnouncement(index: 0)
        case (.tutorial(let index), .previousTutorial):
            phase = .tutorial(index: max(0, index - 1))
        case (.tutorial(let index), .nextTutorial) where index < 2:
            phase = .tutorial(index: index + 1)
        case (.tutorial, .nextTutorial):
            phase = .missionAnnouncement(index: 0)
        case (.missionAnnouncement(let index), .confirmMission):
            phase = .missionActive(index: index)
        case (.missionActive(index: 0), .questAdvanced(nextIndex: 1)):
            phase = .missionAnnouncement(index: 1)
        case (.missionActive(index: 1), .questAdvanced(nextIndex: 2)):
            phase = .missionAnnouncement(index: 2)
        case (.missionActive(index: 2), .questAdvanced(nextIndex: 3)):
            phase = .postOrderPending(index: 3)
        case (.postOrderPending(index: 3), .questAdvanced(nextIndex: 4)):
            phase = .postOrderPending(index: 4)
        case (.postOrderPending(index: 4), .questAdvanced(nextIndex: 5)):
            phase = .postOrderPending(index: 5)
        case (.postOrderPending(index: 5), .questAdvanced(nextIndex: nil)):
            phase = .completionAnnouncement
        case (.completionAnnouncement, .confirmCompletion):
            phase = .completed
        case (_, .failOpen(let activeMissionIndex)):
            phase = .missionActive(index: max(0, min(2, activeMissionIndex)))
        default:
            break
        }
    }
}
