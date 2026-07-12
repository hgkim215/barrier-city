//
//  InteractionModel.swift
//  Barrier City
//
//  공간 인터랙션(근접 트리거 → 예/아니요 패널)의 상태 단일 진실원.
//  판정 로직(evaluate)은 nonisolated 순수 함수로 분리해 향후 테스트 타깃이
//  생기면 바로 단위 테스트를 붙일 수 있게 한다.
//

import RealityKit
import simd
import Observation

/// 현재 배경 씬.
enum GameScene {
    case outdoor
    case indoor
}

/// 근접 인터랙션 트리거 하나(문·키오스크 등). 순수 값 타입.
struct ProximityTrigger: Identifiable, Equatable {
    /// 고유 id (예: "door.enter")
    let id: String
    /// 트리거 중심(맵 좌표 x, z)
    let center: SIMD2<Float>
    /// 진입 반경(m)
    let radius: Float
    /// 패널에 표시할 질문 문구
    let prompt: String
    /// 확인 버튼 라벨
    let confirmLabel: String
    /// 취소 버튼 라벨
    let cancelLabel: String
}

/// 인터랙션 튜닝 상수 단일 진실원(시뮬레이터에서 보고 조정).
enum InteractionTuning {
    /// 문 트리거 진입 반경(m)
    static let doorTriggerRadius: Float = 2.5
    /// 이탈 히스테리시스(m). 경계에서 패널이 깜빡이지 않도록 진입 반경 + 이 값 밖으로
    /// 나가야 닫힌다.
    static let exitHysteresis: Float = 0.4
    /// 패널 표시 높이(m, 맵 좌표 y). 앉은 눈높이보다 살짝 위.
    static let panelHeight: Float = 1.7
    /// DOOR1 프림을 못 찾을 때의 문 트리거 폴백 좌표(맵 좌표 x, z).
    /// _coffee 건물이 (0, 0.3, 20)에 배치돼 있어 문은 그 앞쪽으로 추정. 수동 검증에서 확정.
    static let doorFallbackCenter = SIMD2<Float>(0, 15)
    /// Indoor 전환 직후 스폰 포즈(실내 문 앞, 카운터를 바라봄). 수동 검증에서 확정.
    static let indoorSpawnX: Float = 0
    static let indoorSpawnZ: Float = 4
    static let indoorSpawnHeading: Float = 0
    /// 문 패널 문구
    static let doorPrompt = "안으로 입장하시겠습니까?"
}

/// evaluate의 판정 결과.
struct ProximityVerdict {
    /// 표시해야 할 트리거 id (nil = 패널 숨김)
    let showID: String?
    /// true면 dismissedTriggerID를 해제(범위 이탈 → 재접근 시 재표시)
    let clearDismissed: Bool
}

/// 공간 인터랙션 전역 상태. System이 아닌 SceneEvents.Update 구독(tick)이 읽고 쓴다.
@Observable
@MainActor
final class InteractionModel {

    static let shared = InteractionModel()

    /// 현재 배경 씬.
    var scene: GameScene = .outdoor
    /// 현재 씬의 트리거 목록.
    var triggers: [ProximityTrigger] = []
    /// 표시 중인 패널의 트리거(nil = 숨김).
    var activeTrigger: ProximityTrigger?
    /// "아니요"로 닫힌 트리거 id. 범위 이탈 시 해제되어 재접근하면 다시 뜬다.
    var dismissedTriggerID: String?
    /// 씬 전환 중(패널 버튼 비활성화 + 판정 일시 정지).
    var isTransitioning = false
    /// 전환 실패 등 패널에 표시할 안내 문구.
    var transitionError: String?

    // MARK: - 엔티티·구독 참조(관찰 대상 아님)
    /// 패널 attachment 엔티티(worldRoot 자식).
    @ObservationIgnored var panelEntity: Entity?
    /// 현재 보이는 맵 엔티티(worldRoot 자식). SceneSwitcher가 교체.
    @ObservationIgnored var visibleMap: Entity?
    /// 씬 원점 고정 투명 콜리전 사본. SceneSwitcher가 교체.
    @ObservationIgnored var collisionMap: Entity?
    /// SceneEvents.Update 구독(해제 방지용 보관).
    @ObservationIgnored var updateSubscription: EventSubscription?

    /// "아니요": 현재 패널을 닫고, 범위를 벗어났다 재진입하기 전까지 다시 띄우지 않는다.
    func dismissActive() {
        dismissedTriggerID = activeTrigger?.id
        activeTrigger = nil
    }

    // MARK: - 순수 판정 로직

    /// 플레이어 위치와 트리거 목록으로 "어느 패널을 보여줄지"를 판정한다.
    /// - 진입: 가장 가까운 트리거의 radius 안이고 dismissed가 아니면 표시
    /// - 표시 중: radius + exitHysteresis 밖으로 나가야 닫힘(경계 깜빡임 방지)
    /// - dismissed: 범위 안에서는 유지, 범위 밖으로 나가면 해제(재접근 시 재표시)
    nonisolated static func evaluate(playerX: Float, playerZ: Float,
                                     triggers: [ProximityTrigger],
                                     activeID: String?,
                                     dismissedID: String?) -> ProximityVerdict {
        // 가장 가까운 트리거를 찾는다.
        var best: (trigger: ProximityTrigger, distance: Float)?
        for t in triggers {
            let d = simd_distance(SIMD2(playerX, playerZ), t.center)
            if best == nil || d < best!.distance { best = (t, d) }
        }
        guard let (t, d) = best else {
            return ProximityVerdict(showID: nil, clearDismissed: dismissedID != nil)
        }

        if activeID == t.id {
            // 이미 표시 중: 히스테리시스 반경 밖으로 나가야 닫힘.
            let stillInside = d <= t.radius + InteractionTuning.exitHysteresis
            return ProximityVerdict(showID: stillInside ? t.id : nil, clearDismissed: false)
        }
        if d <= t.radius {
            // 범위 안: 거절 상태면 숨김 유지, 아니면 표시.
            if dismissedID == t.id { return ProximityVerdict(showID: nil, clearDismissed: false) }
            return ProximityVerdict(showID: t.id, clearDismissed: false)
        }
        // 범위 밖: 거절 상태 해제(다시 다가오면 재표시).
        return ProximityVerdict(showID: nil, clearDismissed: dismissedID != nil)
    }
}
