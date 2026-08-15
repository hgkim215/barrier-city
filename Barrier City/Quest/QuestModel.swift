//
//  QuestModel.swift
//  Barrier City
//
//  퀘스트 가이드 HUD의 상태 단일 진실원. InteractionModel과 같은
//  @Observable @MainActor 싱글턴 패턴. 진행 판정은 QuestProgression에 위임.
//

import simd
import Observation

/// 퀘스트 완료를 유발하는 이벤트.
enum QuestEvent: Equatable {
    case enteredIndoor   // 실내(카페) 진입 성공
    case kioskFailed     // 키오스크 "사용하기" → 장벽 안내
    case npcHelpDone     // NPC 최종 응답과 대화 종료 뒤 주문 접수 완료 시 발행
    // 아래 세 이벤트는 후속 UI/음료 에셋 상호작용 연결을 위한 빈 상태 계약이다.
    case drinkReady
    case drinkCollected
    case seatedAtTable
}

/// 퀘스트 한 단계(목표 + 방법 + 완료 조건). 순수 값 타입.
struct QuestStep: Identifiable, Equatable {
    let id: String            // 예: "quest.reachCafe"
    let title: String         // 목표(행동)
    let detail: String        // 방법(보조 설명)
    let completionEvent: QuestEvent
}

/// lazy-follow HUD 튜닝 상수 단일 진실원(시뮬레이터에서 보며 조정).
enum QuestTuning {
    /// head 앞으로 띄우는 거리(m)
    static let forwardDistance: Float = 1.2
    /// 중앙 모달의 head 기준 좌우 오프셋(m, -면 왼쪽)
    static let centerLateralOffset: Float = 0
    /// 중앙 모달의 head 기준 세로 오프셋(m, -면 눈높이보다 아래)
    static let centerVerticalOffset: Float = -0.05
    /// 상단 선행 HUD의 head 기준 좌우 오프셋(m, -면 왼쪽)
    static let hudLateralOffset: Float = -0.4
    /// 상단 선행 HUD의 head 기준 세로 오프셋(m, -면 눈높이보다 아래)
    static let hudVerticalOffset: Float = 0.2
    /// 데드존 각도(rad). 이 안이면 따라가지 않음(15°).
    static let deadZoneAngle: Float = 15 * .pi / 180
    /// 데드존 거리(m). 이 안이면 따라가지 않음.
    static let deadZoneDistance: Float = 0.2
    /// 지수 스무딩 수렴 속도(초당 배율 계수). 클수록 빨리 붙는다.
    static let smoothingRate: Float = 4.0
    /// head 포즈를 못 얻을 때 중앙 모달의 고정 배치 위치(씬 원점 기준).
    static let centerFallbackPosition = SIMD3<Float>(0, 1.45, -1.2)
    /// head 포즈를 못 얻을 때 상단 선행 HUD의 고정 배치 위치(씬 원점 기준).
    static let hudFallbackPosition = SIMD3<Float>(-0.4, 1.65, -1.2)
}

enum QuestAdvanceOutcome: Equatable {
    case ignored
    case advanced(completed: QuestStep, next: QuestStep?)
}

/// 퀘스트 전역 상태.
@Observable
@MainActor
final class QuestModel {

    static let shared = QuestModel()

    /// 앞의 세 단계는 현재 UI에 노출한다. 뒤의 세 단계는 음료 준비·수령·착석 UI가
    /// 구현될 때 연결할 상태 계약이며, 그전까지 가이드 화면에는 표시하지 않는다.
    let steps: [QuestStep] = [
        QuestStep(id: "quest.reachCafe",
                  title: "카페 입구로 이동하세요",
                  detail: "양손으로 바퀴를 잡고 앞으로 밀면 휠체어가 움직입니다",
                  completionEvent: .enteredIndoor),
        QuestStep(id: "quest.tryKiosk",
                  title: "키오스크에서 주문을 시도해 보세요",
                  detail: "키오스크에 가까이 다가가면 화면이 나타납니다",
                  completionEvent: .kioskFailed),
        QuestStep(id: "quest.askStaff",
                  title: "직원에게 도움을 요청하세요",
                  detail: "키오스크가 너무 높아 혼자서는 주문할 수 없습니다",
                  completionEvent: .npcHelpDone),
        QuestStep(id: "quest.waitForDrink",
                  title: "음료가 준비될 때까지 기다리세요",
                  detail: "준비 완료 알림 UI 연결 예정",
                  completionEvent: .drinkReady),
        QuestStep(id: "quest.collectDrink",
                  title: "준비된 음료를 수령하세요",
                  detail: "음료 에셋 상호작용 연결 예정",
                  completionEvent: .drinkCollected),
        QuestStep(id: "quest.takeSeat",
                  title: "지정된 자리로 이동해 앉으세요",
                  detail: "착석 상호작용 연결 예정",
                  completionEvent: .seatedAtTable),
    ]

    /// 현재 단계 인덱스. steps.count가 되어야 전체 체험 퀘스트가 완료된다.
    private(set) var currentIndex = 0
    /// 현재 표시할 목표 단계(전체 완료면 nil).
    var currentStep: QuestStep? {
        currentIndex < steps.count ? steps[currentIndex] : nil
    }

    /// 몰입 공간 재진입 시 1단계로 리셋(InteractionModel 리셋 패턴과 동일).
    func reset() {
        currentIndex = 0
    }

    /// 이벤트 발행. 현재 단계의 완료 이벤트와 일치할 때만 진행한다.
    /// 불일치 이벤트(중복·순서 꼬임)는 무시된다.
    @discardableResult
    func advance(on event: QuestEvent) -> QuestAdvanceOutcome {
        guard let step = currentStep else { return .ignored }
        let nextIndex = QuestProgression.nextIndex(
            currentIndex: currentIndex,
            stepCount: steps.count,
            eventMatchesCurrent: event == step.completionEvent)
        guard nextIndex != currentIndex else { return .ignored }

        currentIndex = nextIndex
        return .advanced(completed: step, next: currentStep)
    }
}
