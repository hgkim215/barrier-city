//
//  QuestModel.swift
//  Barrier City
//
//  퀘스트 가이드 HUD의 상태 단일 진실원. InteractionModel과 같은
//  @Observable @MainActor 싱글턴 패턴. 진행 판정은 QuestProgression에 위임.
//

import RealityKit
import simd
import Observation

/// 퀘스트 완료를 유발하는 이벤트.
enum QuestEvent: Equatable {
    case enteredIndoor   // 실내(카페) 진입 성공
    case kioskFailed     // 키오스크 "사용하기" → 장벽 안내
    case npcHelpDone     // 정의만 — 발행은 NPC 씬 배치 후(이번 스코프 밖)
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
    /// head 기준 좌우 오프셋(m, -면 왼쪽)
    static let lateralOffset: Float = -0.35
    /// head 기준 세로 오프셋(m, -면 눈높이보다 아래)
    static let verticalOffset: Float = -0.15
    /// 데드존 각도(rad). 이 안이면 따라가지 않음(15°).
    static let deadZoneAngle: Float = 15 * .pi / 180
    /// 데드존 거리(m). 이 안이면 따라가지 않음.
    static let deadZoneDistance: Float = 0.2
    /// 지수 스무딩 수렴 속도(초당 배율 계수). 클수록 빨리 붙는다.
    static let smoothingRate: Float = 4.0
    /// 완료 연출 유지 시간(초).
    static let completedHoldSeconds: Double = 1.5
    /// head 포즈를 못 얻을 때 고정 배치 위치(씬 원점 기준).
    static let fallbackPosition = SIMD3<Float>(-0.35, 1.4, -1.2)
}

/// 퀘스트 전역 상태.
@Observable
@MainActor
final class QuestModel {

    static let shared = QuestModel()

    /// 고정 3단계 시퀀스(문구는 실기기 흐름 기준, 스펙 확정값).
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
    ]

    /// 현재 단계 인덱스. steps.count면 전체 완료(이번 스코프에선 도달 안 함).
    private(set) var currentIndex = 0
    /// 완료 연출용: 방금 완료된 단계(잠시 표시 후 nil).
    private(set) var justCompletedStep: QuestStep?

    /// 현재 표시할 목표 단계(전체 완료면 nil).
    var currentStep: QuestStep? {
        currentIndex < steps.count ? steps[currentIndex] : nil
    }

    /// 몰입 공간 재진입 시 1단계로 리셋(InteractionModel 리셋 패턴과 동일).
    func reset() {
        currentIndex = 0
        justCompletedStep = nil
    }

    /// 이벤트 발행. 현재 단계의 완료 이벤트와 일치할 때만 진행하고 완료 연출을 띄운다.
    /// 불일치 이벤트(중복·순서 꼬임)는 무시된다.
    func advance(on event: QuestEvent) {
        guard let step = currentStep else { return }
        let matches = (event == step.completionEvent)
        let next = QuestProgression.nextIndex(currentIndex: currentIndex,
                                              stepCount: steps.count,
                                              eventMatchesCurrent: matches)
        guard next != currentIndex else { return }   // 변화 없으면 무시
        justCompletedStep = step
        currentIndex = next
        // 완료 연출을 completedHoldSeconds 후 해제(그 사이 새 완료가 오면 최신 것 우선).
        Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(QuestTuning.completedHoldSeconds))
            if self.justCompletedStep == step { self.justCompletedStep = nil }
        }
    }
}
