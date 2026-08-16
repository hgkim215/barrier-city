//
//  InteractionModel.swift
//  Barrier City
//
//  공간 인터랙션(근접 트리거 → 예/아니요 패널)의 상태 단일 진실원.
//  판정 로직(evaluate)은 nonisolated 순수 함수로 분리해 향후 테스트 타깃이
//  생기면 바로 단위 테스트를 붙일 수 있게 한다.
//

import Foundation
import RealityKit
import simd
import Observation

/// 현재 배경 씬.
enum GameScene: Equatable {
    case outdoor
    case indoor
}

/// 트리거가 활성화됐을 때 띄우는 UI 종류.
enum TriggerKind {
    /// 예/아니요 확인 패널(문 등)
    case yesNoPrompt
    /// 키오스크 주문 화면(고정 높이 장벽)
    case kioskScreen
}

/// 근접 인터랙션 트리거 하나(문·키오스크 등). 순수 값 타입.
struct ProximityTrigger: Identifiable, Equatable {
    /// 고유 id (예: "door.enter")
    let id: String
    /// 트리거 중심(맵 좌표 x, z)
    let center: SIMD2<Float>
    /// 진입 반경(m)
    let radius: Float
    /// 활성화 시 띄울 UI 종류
    let kind: TriggerKind
    /// 패널에 표시할 질문 문구(kioskScreen은 화면 타이틀로 사용)
    let prompt: String
    /// 확인 버튼 라벨(yesNoPrompt 전용)
    let confirmLabel: String
    /// 취소 버튼 라벨(yesNoPrompt 전용)
    let cancelLabel: String

    /// kind 기본값 .yesNoPrompt, 라벨 기본값 ""이라 기존 문 트리거 생성부는 무수정.
    init(id: String, center: SIMD2<Float>, radius: Float,
         kind: TriggerKind = .yesNoPrompt,
         prompt: String, confirmLabel: String = "", cancelLabel: String = "") {
        self.id = id
        self.center = center
        self.radius = radius
        self.kind = kind
        self.prompt = prompt
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
    }
}

/// 인터랙션 튜닝 상수 단일 진실원(시뮬레이터에서 보고 조정).
enum InteractionTuning {
    /// 문 트리거 진입 반경(m)
    static let doorTriggerRadius: Float = 1.1
    /// Outdoor 공통 바닥 충돌체의 한 변 길이(m).
    static let outdoorGroundPlaneSize: Float = 16
    /// 휠체어 전체가 바닥에 지지되도록 리스폰 경계에서 안쪽으로 두는 여유(m).
    static let outdoorSpawnSafetyMargin: Float = 0.5
    /// 이탈 히스테리시스(m). 경계에서 패널이 깜빡이지 않도록 진입 반경 + 이 값 밖으로
    /// 나가야 닫힌다.
    nonisolated static let exitHysteresis: Float = 0.4
    /// 패널 표시 높이(m, 맵 좌표 y). 키오스크 빌보드 폴백에서 사용.
    static let panelHeight: Float = 1.7
    /// 문 선택 패널을 사용자 눈앞 정면에 두는 content-root 월드 좌표(m).
    nonisolated static let doorPromptEyeFrontPosition = SIMD3<Float>(0, 1.45, -1.2)
    /// 최신 Outdoor의 Door 프림을 못 찾을 때 쓰는 authored 문 좌표(맵 좌표 x, z).
    static let doorFallbackCenter = SIMD2<Float>(-0.16957682, -5.889111)
    /// Indoor marker 조회 실패 시 쓰는 문 안쪽 폴백 포즈.
    /// 실제 포즈는 SceneSwitcher가 Door→Kiosk 방향으로 동적으로 계산한다.
    static let indoorSpawnX: Float = 0
    static let indoorSpawnZ: Float = -4.5
    static let indoorSpawnHeading: Float = .pi
    static let indoorSpawnDistanceFromDoor: Float = 1.2
    /// 문 패널 문구
    static let doorPrompt = "안으로 입장하시겠습니까?"

    /// 키오스크 트리거 진입 반경(m). 휠체어로 접근할 때 스치듯 지나가지 않게 넉넉히.
    static let kioskTriggerRadius: Float = 3.0
    /// 키오스크 패널을 키오스크 표면에서 사용자 쪽으로 당기는 거리(m). 박스에 안 묻히게.
    nonisolated static let kioskPanelForwardOffset: Float = 0.8
    /// Kiosk 프림을 못 찾을 때의 키오스크 트리거 폴백 좌표(Indoor 자산 기준).
    static let kioskFallbackCenter = SIMD2<Float>(0.85, 1.65)
    /// 키오스크 화면 타이틀 겸 트리거 prompt 값.
    static let kioskTitle = "주문하기"
}

/// 패널 종류별 표면 오프셋을 적용하는 순수 월드 좌표 계산.
enum InteractionPanelPlacement {
    nonisolated static func worldPosition(
        _ worldPosition: SIMD3<Float>,
        toward viewerPosition: SIMD3<Float>,
        kind: TriggerKind
    ) -> SIMD3<Float> {
        switch kind {
        case .yesNoPrompt:
            return InteractionTuning.doorPromptEyeFrontPosition
        case .kioskScreen:
            break
        }

        var result = worldPosition
        let towardViewer = SIMD2(
            viewerPosition.x - worldPosition.x,
            viewerPosition.z - worldPosition.z)
        let distance = simd_length(towardViewer)
        guard distance > 0.001 else { return result }
        let displacement = towardViewer / distance * InteractionTuning.kioskPanelForwardOffset
        result.x += displacement.x
        result.z += displacement.y
        return result
    }
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
    var isTransitioning: Bool { transitionSession.isTransitioning }
    /// 전환 실패 등 패널에 표시할 안내 문구.
    var transitionError: String?

    // MARK: - 엔티티·구독 참조(관찰 대상 아님)
    /// 문 예/아니요 패널 attachment 엔티티(content root 자식).
    @ObservationIgnored var panelEntity: Entity?
    /// 키오스크 주문 화면 attachment 엔티티(worldRoot 자식).
    @ObservationIgnored var kioskPanelEntity: Entity?
    /// 실제 Screen 배치 성공 시 손 위치를 변환할 기준 Plane.
    @ObservationIgnored var kioskScreenPlane: Entity?
    /// Screen Plane의 로컬 반너비·반높이.
    @ObservationIgnored var kioskScreenHalfSize = SIMD2<Float>.zero
    /// true면 Screen 배치 실패로 기존 월드 빌보드 배치를 사용한다.
    @ObservationIgnored var kioskUsesBillboardFallback = true
    /// 키오스크 메뉴 표시·입력·장벽·도움 요청 상태.
    private var kioskState = KioskInteractionState()
    /// 왼손과 오른손의 이동 이력을 섞지 않도록 손별 detector를 유지한다.
    @ObservationIgnored private var kioskReachDetectors: [KioskHandSide: KioskReachAttemptDetector] = [:]
    /// attachment가 없을 때 Mission 2를 한 번만 fail-open하기 위한 세션 플래그.
    @ObservationIgnored var kioskFailOpenSent = false
    /// 현재 보이는 맵 엔티티(worldRoot 자식). SceneSwitcher가 교체.
    @ObservationIgnored var visibleMap: Entity?
    /// 씬 원점 고정 투명 콜리전 사본. SceneSwitcher가 교체.
    @ObservationIgnored var collisionMap: Entity?
    /// SceneEvents.Update 구독(해제 방지용 보관).
    @ObservationIgnored var updateSubscription: EventSubscription?
    private var transitionSession = SceneTransitionSession()
    @ObservationIgnored private var transitionTask: Task<Void, Never>?

    /// "아니요": 현재 패널을 닫고, 범위를 벗어났다 재진입하기 전까지 다시 띄우지 않는다.
    func dismissActive() {
        dismissedTriggerID = activeTrigger?.id
        activeTrigger = nil
    }

    // MARK: - 키오스크 상태

    var kioskMenuVisible: Bool { kioskState.menuVisible }
    var kioskInputEnabled: Bool { kioskState.inputEnabled }
    var kioskBarrierVisible: Bool { kioskState.barrierVisible }
    var kioskSelectedCategory: KioskCategory { kioskState.selectedCategory }
    var kioskSelectedMenuID: String? { kioskState.selectedMenuID }

    func updateKioskContext(
        isIndoor: Bool,
        isNear: Bool,
        isMissionTwoActive: Bool,
        isGuideLocked: Bool
    ) {
        kioskState.updateContext(
            isIndoor: isIndoor,
            isNear: isNear,
            isMissionTwoActive: isMissionTwoActive,
            isGuideLocked: isGuideLocked)
        if !kioskState.inputEnabled {
            resetKioskReachDetectors()
        }
    }

    @discardableResult
    func attemptKioskUse(_ source: KioskAttemptSource) -> Bool {
        kioskState.attempt(source)
    }

    func selectKioskCategory(
        _ category: KioskCategory,
        source: KioskAttemptSource = .gazePinch
    ) -> KioskCategorySelectionResult {
        kioskState.selectCategory(category, source: source)
    }

    @discardableResult
    func selectKioskMenu(id: String) -> Bool {
        kioskState.selectMenu(id: id)
    }

    @discardableResult
    func attemptRestrictedKioskCategory(_ source: KioskAttemptSource) -> Bool {
        kioskState.attemptRestrictedCategory(source)
    }

    @discardableResult
    func dismissKioskBarrier() -> Bool {
        kioskState.dismissBarrier()
    }

    @discardableResult
    func requestKioskStaffHelp() -> Bool {
        guard kioskState.requestStaffHelp() else { return false }
        dismissActive()
        resetKioskReachDetectors()
        return true
    }

    /// 몰입 공간 종료 시 이전 RealityKit 장면과 구독을 더 이상 붙잡지 않는다.
    /// 다음 진입은 `InteractionSetup.install`이 완전히 새로운 참조로 다시 구성한다.
    func tearDown() {
        endImmersiveSession()
        updateSubscription?.cancel()
        updateSubscription = nil
        panelEntity = nil
        kioskPanelEntity = nil
        visibleMap = nil
        collisionMap = nil
        triggers = []
        activeTrigger = nil
        dismissedTriggerID = nil
        transitionError = nil
        scene = .outdoor
    }

    func processKioskLocalHandSample(
        side: KioskHandSide,
        localPosition: SIMD3<Float>,
        timestamp: TimeInterval,
        isTracked: Bool,
        halfWidth: Float,
        halfHeight: Float
    ) {
        guard kioskState.inputEnabled else {
            kioskReachDetectors[side]?.reset()
            return
        }
        let attempted = kioskReachDetectors[side, default: KioskReachAttemptDetector()].sample(
            position: localPosition,
            timestamp: timestamp,
            isTracked: isTracked,
            halfWidth: halfWidth,
            halfHeight: halfHeight)
        if attempted {
            _ = attemptRestrictedKioskCategory(.handReach)
        }
    }

    func processKioskHandSample(
        side: KioskHandSide,
        worldPosition: SIMD3<Float>,
        timestamp: TimeInterval,
        isTracked: Bool
    ) {
        guard let plane = kioskScreenPlane else {
            kioskReachDetectors[side]?.reset()
            return
        }
        let localPosition = plane.convert(position: worldPosition, from: nil)
        processKioskLocalHandSample(
            side: side,
            localPosition: localPosition,
            timestamp: timestamp,
            isTracked: isTracked,
            halfWidth: kioskScreenHalfSize.x,
            halfHeight: kioskScreenHalfSize.y)
    }

    func applyKioskScreenPlacement(_ placement: KioskScreenPlacement) {
        switch placement {
        case .attached(let plane, let halfSize):
            kioskScreenPlane = plane
            kioskScreenHalfSize = halfSize
            kioskUsesBillboardFallback = false
        case .billboardFallback:
            kioskScreenPlane = nil
            kioskScreenHalfSize = .zero
            kioskUsesBillboardFallback = true
        }
        resetKioskReachDetectors()
    }

    func resetKioskSession() {
        kioskState.reset()
        kioskFailOpenSent = false
        kioskScreenPlane = nil
        kioskScreenHalfSize = .zero
        kioskUsesBillboardFallback = true
        resetKioskReachDetectors()
    }

    private func resetKioskReachDetectors() {
        kioskReachDetectors.removeAll(keepingCapacity: true)
    }

    // MARK: - 씬 전환 수명주기

    func beginImmersiveSession() {
        transitionTask?.cancel()
        transitionTask = nil
        transitionSession.beginSession()
        resetKioskSession()
    }

    func endImmersiveSession() {
        transitionTask?.cancel()
        transitionTask = nil
        transitionSession.endSession()
        resetKioskSession()
    }

    func startSceneTransition(
        _ operation: @escaping @MainActor (SceneTransitionToken) async -> Void
    ) {
        guard let token = transitionSession.beginTransition() else { return }
        transitionTask = Task { @MainActor [weak self] in
            await operation(token)
            guard let self else { return }
            transitionSession.finishTransition(token)
            if !transitionSession.isTransitioning {
                transitionTask = nil
            }
        }
    }

    func isCurrentTransition(_ token: SceneTransitionToken) -> Bool {
        !Task.isCancelled && transitionSession.isCurrent(token)
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
