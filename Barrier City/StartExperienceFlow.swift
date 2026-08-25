import Foundation

enum AppSceneID {
    static let start = "start"
    static let debugControl = "debug-control"
    static let npcDialogueTest = "npc-dialogue-test"
    static let wheelchair = "wheelchair"
    /// 몰입 공간이 뜨기 전부터 로딩 내내 떠 있는 볼륨 윈도우(SplashOverlayView).
    /// 몰입 공간을 여는 진입점(StartScreenView, ControlPanelView 디버그 패널)이
    /// 열고, 실제로 씬 로딩이 끝나는 시점은 ImmersiveView가 닫는다.
    static let splash = "splash"
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
