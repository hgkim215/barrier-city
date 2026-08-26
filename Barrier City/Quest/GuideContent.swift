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
    /// 시작 화면 CTA와 같은 노랑(#FDD92C). 배지 테두리·글자, 진행 표시에 쓴다.
    static let accent = Color(red: 0.992, green: 0.851, blue: 0.173)
    /// 그라데이션 아래쪽 주황(#FE950A).
    static let accentDeep = Color(red: 0.996, green: 0.584, blue: 0.039)

    /// StartScreenView의 시작 버튼과 동일한 세로 그라데이션.
    /// 온보딩 → 체험으로 넘어가는 동안 주 버튼의 인상이 끊기지 않게 맞춘다.
    static let accentGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .top,
        endPoint: .bottom)
}

/// 온보딩 카드(인트로 · 튜토리얼)의 치수. 두 카드가 같은 questHUD attachment를
/// 공유하므로 폭을 함께 두어 단계 전환에서 패널이 좌우로 흔들리지 않게 한다.
enum GuideCardMetrics {
    /// 안내 영상 패널. 원본이 1280x720이라 16:9로 맞춘다(레터박스 없음).
    static let videoWidth: CGFloat = 840
    static let videoHeight: CGFloat = videoWidth * 9 / 16       // 472.5
    /// 영상을 감싸는 글래스 테두리 두께.
    static let videoFramePadding: CGFloat = 10
    static let videoPanelWidth: CGFloat = videoWidth + videoFramePadding * 2
    static let videoPanelHeight: CGFloat = videoHeight + videoFramePadding * 2

    /// 영상 패널과 아래 텍스트 카드 사이 간격.
    static let panelGap: CGFloat = 26

    /// 텍스트 카드. 인트로와 튜토리얼이 폭과 높이를 모두 공유해야
    /// 단계가 바뀌어도 카드가 제자리에 머문다.
    static let width: CGFloat = 720
    static let padding: CGFloat = 32
    static let cardHeight: CGFloat = 380

    /// 온보딩 전체가 차지하는 고정 영역.
    ///
    /// 인트로에는 영상이 없지만 이 높이를 똑같이 잡고 **하단 정렬**한다.
    /// 그래야 "다음"을 눌렀을 때 카드가 아래로 밀려나지 않고, 비어 있던
    /// 위쪽 자리에 영상 패널만 나타난다.
    static let stackWidth: CGFloat = max(videoPanelWidth, width)
    static let stackHeight: CGFloat = videoPanelHeight + panelGap + cardHeight

    /// 미션 안내 모달과 미션 목록 HUD의 폭.
    static let missionWidth: CGFloat = 780
    static let missionListWidth: CGFloat = 520
}

extension View {
    /// 온보딩 카드를 아래쪽 기준선에 고정한다.
    func onboardingAnchored() -> some View {
        frame(width: GuideCardMetrics.stackWidth,
              height: GuideCardMetrics.stackHeight,
              alignment: .bottom)
    }
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
            videoResourceName: "Grab"
        ),
        TutorialGuideStep(
            id: 1,
            title: "방향 전환하기",
            detail: "한쪽 바퀴를 움직여\n원하는 방향으로 회전할 수 있습니다.",
            videoResourceName: "Turn"
        ),
        TutorialGuideStep(
            id: 2,
            title: "직진 · 후진하기",
            detail: "양쪽 바퀴를 같은 방향으로 움직이면\n앞으로 또는 뒤로 이동할 수 있습니다.",
            videoResourceName: "BackAndForth"
        ),
    ]

    static let missions = [
        MissionNarrative(
            situation: "음료 한 잔이 마시고 싶다.\n앞에 보이는 카페로 들어가자.",
            action: "휠체어를 조작하여 카페 내부로 들어가세요."
        ),
        MissionNarrative(
            situation: "이번에 신상으로 나온\n‘레인보우 마카롱 스무디’가 마시고 싶다.",
            action: "키오스크에서 음료 주문을 시도해 보세요."
        ),
        MissionNarrative(
            situation: "키오스크 화면이 너무 높아\n혼자 주문하기 어렵다.",
            action: "직원에게 직접 도움을 요청해 보세요."
        ),
        MissionNarrative(
            situation: "직원이 주문을 접수하고 음료 제조를 시작했다.\n음료가 준비될 때까지 잠시 대기하자.",
            action: "음료 제조가 완료될 때까지 카운터 앞에서 대기하세요."
        ),
        MissionNarrative(
            situation: "주문한 음료가 카운터 위에 준비되었다.\n직원이 음료를 호출했다.",
            action: "카운터 위의 쟁반에 놓인 레인보우 마카롱 스무디를 터치하여 수령하세요."
        ),
        MissionNarrative(
            situation: "음료를 무사히 수령했다.\n휠체어로 편하게 머무를 수 있는 지정 좌석으로 이동하자.",
            action: "파란색 WayPoint 마커가 표시된 지정 테이블 좌석으로 이동하세요."
        ),
    ]
}
