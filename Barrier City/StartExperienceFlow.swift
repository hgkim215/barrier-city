import Foundation

enum AppSceneID {
    static let start = "start"
    static let debugControl = "debug-control"
    static let npcDialogueTest = "npc-dialogue-test"
    static let wheelchair = "wheelchair"
}

enum DebugWindowRoute: String, Codable, Hashable {
    case controlPanel
}

enum StartExperienceEvent {
    case immersiveOpened
    case immersiveOpenCancelled
    case immersiveOpenFailed
    case immersiveEnded
}

enum StartExperienceWindowAction: Equatable {
    case none
    case dismissStartWindow
    case openStartWindow
}

struct StartExperienceOpenResolution: Equatable {
    let windowAction: StartExperienceWindowAction
    let errorMessage: String?
}

enum StartExperienceFlow {
    static func resolve(_ event: StartExperienceEvent) -> StartExperienceOpenResolution {
        switch event {
        case .immersiveOpened:
            StartExperienceOpenResolution(
                windowAction: .dismissStartWindow,
                errorMessage: nil)
        case .immersiveOpenCancelled:
            StartExperienceOpenResolution(
                windowAction: .none,
                errorMessage: "몰입 공간 열기가 취소되었습니다.")
        case .immersiveOpenFailed:
            StartExperienceOpenResolution(
                windowAction: .none,
                errorMessage: "몰입 공간을 열 수 없습니다. 잠시 후 다시 시도해 주세요.")
        case .immersiveEnded:
            StartExperienceOpenResolution(
                windowAction: .openStartWindow,
                errorMessage: nil)
        }
    }
}
