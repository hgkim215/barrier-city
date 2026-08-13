import SwiftUI

struct TutorialGuideStep: Identifiable, Equatable {
    let id: Int
    let title: String
    let detail: String
    let videoResourceName: String
}

struct MissionNarrative: Equatable {
    let situation: String
    let action: String
}

enum GuideTheme {
    /// Figma brand accent: #00EAFF.
    static let accent = Color(red: 0, green: 234.0 / 255.0, blue: 1)
}

enum GuideContent {
    static let introductionTitle = "휠체어 체험을 시작합니다."
    static let introductionBody = "지금부터 휠체어를 사용하는 사용자의 시점에서 일상을 경험하게 됩니다.\n먼저 간단한 조작을 익혀보세요."
    static let completionTitle = "Barrier City 체험을 완료했습니다."
    static let completionBody = "접근하기 어려운 공간과 서비스가\n일상에 어떤 장벽이 되는지 돌아보세요."

    static let tutorials = [
        TutorialGuideStep(
            id: 0,
            title: "바퀴 조작하기",
            detail: "바퀴를 잡으면 파란색으로 표시됩니다.\n손을 앞뒤로 움직여 바퀴를 회전시켜 보세요.",
            videoResourceName: "guide-wheel-control"
        ),
        TutorialGuideStep(
            id: 1,
            title: "방향 전환하기",
            detail: "한쪽 바퀴를 움직여\n원하는 방향으로 회전할 수 있습니다.",
            videoResourceName: "guide-turning"
        ),
        TutorialGuideStep(
            id: 2,
            title: "직진 · 후진하기",
            detail: "양쪽 바퀴를 같은 방향으로 움직이면\n앞으로 또는 뒤로 이동할 수 있습니다.",
            videoResourceName: "guide-straight-drive"
        ),
    ]

    static let missions = [
        MissionNarrative(
            situation: "음료 한 잔이 마시고 싶다.\n앞에 보이는 카페로 들어가자.",
            action: "휠체어를 이동하여 카페 입구로 이동하세요."
        ),
        MissionNarrative(
            situation: "이번에 신상으로 나온\n‘레인보우 마카롱 스무디’가 마시고 싶다.",
            action: "키오스크에서 음료 주문을 시도해 보세요."
        ),
        MissionNarrative(
            situation: "키오스크 화면이 너무 높아\n혼자 주문하기 어렵다.",
            action: "직원에게 직접 도움을 요청해 보세요."
        ),
    ]
}
