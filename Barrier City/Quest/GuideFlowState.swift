import Foundation

enum GuidePhase: Equatable {
    case introduction
    case tutorial(index: Int)
    case missionAnnouncement(index: Int)
    case missionActive(index: Int)
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
        case .missionActive, .completed: false
        case .introduction, .tutorial, .missionAnnouncement, .completionAnnouncement: true
        }
    }

    var placement: GuidePlacement {
        switch phase {
        case .missionActive, .completed: .upperLeadingHUD
        default: .centerModal
        }
    }

    var visibleMissionCount: Int {
        switch phase {
        case .missionAnnouncement(let index), .missionActive(let index): index + 1
        case .completionAnnouncement, .completed: 3
        case .introduction, .tutorial: 0
        }
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
        case (.missionActive, .questAdvanced(let nextIndex)):
            phase = nextIndex.map { .missionAnnouncement(index: $0) } ?? .completionAnnouncement
        case (.completionAnnouncement, .confirmCompletion):
            phase = .completed
        case (_, .failOpen(let activeMissionIndex)):
            phase = .missionActive(index: max(0, min(2, activeMissionIndex)))
        default:
            break
        }
    }
}
