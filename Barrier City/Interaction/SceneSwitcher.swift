//
//  SceneSwitcher.swift
//  Barrier City
//
//  Outdoor("Outdoor") → Indoor("Indoor") 배경 전환.
//  같은 몰입 공간을 유지한 채 ① worldRoot의 시각 맵 교체 ② 씬 원점의 투명 콜리전
//  사본 교체 ③ Door→Kiosk 방향으로 실내 문 안쪽 포즈를 계산한다.
//
import RealityKit
import RealityKitContent
import simd

@MainActor
enum SceneSwitcher {

    private struct PreparedIndoorScene {
        let visible: Entity
        let collision: Entity
        let collisionShapeCount: Int
        let smoothie: Entity?
        let waypoint: Entity?
        let cake: Entity?
        let latte: Entity?
        /// NPC 접근 금지 영역(NPCGuestCoordinator.enterIndoor로 전달)의 실제 근거인
        /// /Root/collision 밑 Cube~Cube_11 콜리전 프록시. prepareVisible이 그
        /// ModelComponent를 지우기 전에 미리 재 둔다(아래 prepareIndoorScene 참고).
        let collisionCubeAreas: [SceneEntityPreparation.CapturedArea]
    }

    /// /Root/collision 밑에 있는 벽·가구 콜리전 프록시 이름들("Cube", "Cube_1"...
    /// "Cube_11"). NPC 접근 금지 영역의 실제 소스로 쓴다 — 테이블 좌석 바운즈에
    /// 임의 여백을 더하는 예전 계산(seatClusterExclusionMargin) 대신, 휠체어가 이미
    /// 물리적으로 충돌하는 것과 같은 authored 콜리전 형상을 그대로 쓴다.
    private static let indoorCollisionCubeNames = ["Cube"] + (1...11).map { "Cube_\($0)" }

    private struct IndoorLayout {
        let kioskCenter: SIMD2<Float>
        let spawn: SIMD2<Float>
        let heading: Float
    }

    private static var preloadedIndoorScene: PreparedIndoorScene?
    private static var preloadTask: Task<PreparedIndoorScene?, Never>?

    /// 몰입 공간 진입 시(Outdoor를 보여주는 동안) 미리 호출해 Indoor 씬을 로드해
    /// 캐시해둔다. 실제 "예" 선택 시(switchToIndoor) 이미 준비돼 있으면 그 순간의
    /// 로딩 없이 바로 재사용한다. 실패해도 조용히 넘어가고, 전환 시점에 평소대로
    /// 다시 시도한다.
    static func preloadIndoorScene() async {
        guard preloadedIndoorScene == nil else { return }
        if let existing = preloadTask {
            preloadedIndoorScene = await existing.value
            return
        }
        let task = Task<PreparedIndoorScene?, Never> {
            try? await prepareIndoorScene()
        }
        preloadTask = task
        preloadedIndoorScene = await task.value
        preloadTask = nil
    }

    /// 캐시된 프리로드 결과가 있으면 그걸 쓰고(한 번만), 없으면 지금 바로 새로
    /// 로드한다.
    private static func consumePreloadedIndoorScene() async throws -> PreparedIndoorScene {
        if let cached = preloadedIndoorScene {
            preloadedIndoorScene = nil
            return cached
        }
        if let task = preloadTask {
            preloadTask = nil
            if let value = await task.value { return value }
        }
        return try await prepareIndoorScene()
    }

    static func requestIndoorTransition() {
        let im = InteractionModel.shared
        im.startSceneTransition { token in
            await switchToIndoor(token: token)
        }
    }

    /// 이미 실내에 있는 상태에서 개발 리스폰 시 시작 위치와 자세를 문 안쪽 스폰 좌표로 초기화한다.
    static func resetIndoorPose(app: AppModel) {
        let im = InteractionModel.shared
        guard im.scene == .indoor,
              let worldRoot = app.worldRoot,
              let indoorVisible = im.visibleMap else { return }
        let layout = resolveIndoorLayout(in: indoorVisible, relativeTo: worldRoot)
        app.restart()
        app.motion.positionX = layout.spawn.x
        app.motion.positionZ = layout.spawn.y
        app.motion.heading = layout.heading
        if let groundHeight = im.outdoorGroundLayout?.height {
            app.motion.chairHeight = groundHeight
            app.motion.groundHeight = groundHeight
        }
    }

    /// "예" 선택 시 호출. Outdoor에서만 동작하며, 실패 시 Outdoor를 유지하고
    /// 패널에 안내 문구를 띄운다.
    private static func switchToIndoor(token: SceneTransitionToken) async {
        let im = InteractionModel.shared
        guard im.isCurrentTransition(token), im.scene == .outdoor,
              let app = AppModel.current, let worldRoot = app.worldRoot else {
            im.transitionError = "지금은 들어갈 수 없어요. 잠시 후 다시 시도해 주세요."
            return
        }

        // 애셋 로드·정착이 끝날 때까지 화면을 가려 준비 과정을 자연스럽게 숨긴다.
        // 실패로 중간에 빠져나가는 경로는 여기서 바로 되돌리고, 성공 경로는 NPC가
        // 움직이기 시작한 뒤 fadeIn을 호출한다(아래 didCommit 처리부 참고).
        SceneFadeOverlay.shared.fadeOut()
        var didCommit = false
        defer { if !didCommit { SceneFadeOverlay.shared.fadeIn() } }

        // 1) 새 시각·콜리전 엔티티를 기존 장면 밖에서 모두 준비한다. 이 구간에서는
        //    현재 맵, 플레이어 포즈, 인터랙션 상태를 전혀 변경하지 않는다.
        let prepared: PreparedIndoorScene
        do {
            prepared = try await consumePreloadedIndoorScene()
        } catch is CancellationError {
            im.transitionError = "장면 전환이 취소되었습니다."
            return
        } catch {
            im.transitionError = "지금은 들어갈 수 없어요. 잠시 후 다시 시도해 주세요."
            return
        }

        // 로드 중 몰입 공간이 닫혔거나 다른 세션으로 교체됐다면 준비한 엔티티를 버린다.
        guard im.isCurrentTransition(token),
              AppModel.current === app,
              app.worldRoot === worldRoot,
              im.scene == .outdoor,
              let oldVisible = im.visibleMap,
              let oldCollision = im.collisionMap,
              let collisionParent = oldCollision.parent else {
            im.transitionError = "장면 구성 준비가 완료되지 않았습니다. 잠시 후 다시 시도해 주세요."
            return
        }

        guard prepared.visible.findEntity(named: "Barista") != nil else {
            im.transitionError = "지금은 들어갈 수 없어요. 잠시 후 다시 시도해 주세요."
            return
        }

        // 좌표 계산을 위해 새 엔티티를 비활성 상태로 같은 계층에 잠시 붙인다.
        // 엔티티 자체가 비활성이므로 렌더링·충돌 판정에는 아직 참여하지 않는다.
        prepared.visible.isEnabled = false
        prepared.collision.isEnabled = false
        worldRoot.addChild(prepared.visible)
        collisionParent.addChild(prepared.collision)
        let layout = resolveIndoorLayout(in: prepared.visible, relativeTo: worldRoot)

        // 2) 이 아래에는 await/throw가 없다. 화면, 콜리전, 포즈, 인터랙션과 가이드를
        //    한 MainActor 실행 구간에서 커밋해 외부가 중간 상태를 관찰하지 못하게 한다.
        app.npcClerk.enterIndoor(worldRoot: worldRoot,
                                 indoorMap: prepared.visible,
                                 kioskCenter: layout.kioskCenter,
                                 isTransitionCurrent: {
                                     im.isCurrentTransition(token)
                                 })
        guard im.isCurrentTransition(token) else { return }
        app.rainbowSmoothiePresenter.install(
            smoothie: prepared.smoothie,
            in: prepared.visible)
        app.waypointPresenter.install(in: prepared.visible)
        app.rainbowSmoothieServing.enterIndoor()
        app.npcGuests.enterIndoor(worldRoot: worldRoot,
                                  indoorMap: prepared.visible,
                                  cakeTemplate: prepared.cake,
                                  latteTemplate: prepared.latte,
                                  collisionCubeAreas: prepared.collisionCubeAreas)
        app.restart()
        app.motion.positionX = layout.spawn.x
        app.motion.positionZ = layout.spawn.y
        app.motion.heading = layout.heading
        app.motion.collisionShapeCount = prepared.collisionShapeCount
        // restart()가 chairHeight를 0으로 되돌리지만, 실내는 아직 자체 바닥 콜리전이 없어
        // 상주하는 Outdoor 접지 fallback 높이를 그대로 쓴다(위 prepareIndoorScene 주석 참고).
        // 재동기화하지 않으면 첫 프레임들에서 0과 실제 접지 높이 사이 격차가 커서 단차 보정이
        // 반복 트리거되며 "덜덜덜" 소리와 시각적 튐이 났다.
        if let groundHeight = im.outdoorGroundLayout?.height {
            app.motion.chairHeight = groundHeight
            app.motion.groundHeight = groundHeight
        }

        im.scene = .indoor
        im.visibleMap = prepared.visible
        im.collisionMap = prepared.collision
        im.triggers = [ProximityTrigger(
            id: "kiosk.order",
            center: layout.kioskCenter,
            radius: InteractionTuning.kioskTriggerRadius,
            kind: .kioskScreen,
            prompt: InteractionTuning.kioskTitle)]
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.transitionError = nil
        im.panelEntity?.isEnabled = false
        im.updateKioskContext(
            isIndoor: true,
            isNear: false,
            isMissionTwoActive: false,
            isGuideLocked: GuideFlowModel.shared.isInteractionLocked)

        if let kioskPanel = im.kioskPanelEntity {
            let placement = KioskScreenPresenter.install(
                attachment: kioskPanel,
                in: prepared.visible,
                worldRoot: worldRoot)
            im.applyKioskScreenPlacement(placement)
            kioskPanel.isEnabled = !im.kioskUsesBillboardFallback
        } else {
            im.applyKioskScreenPlacement(.billboardFallback)
            print("⚠️ kioskScreen attachment 없음 — Mission 2 진입 시 fail-open")
        }

        oldVisible.isEnabled = false
        oldCollision.isEnabled = false
        prepared.visible.isEnabled = true
        prepared.collision.isEnabled = true
        oldVisible.removeFromParent()
        oldCollision.removeFromParent()

        GuideFlowModel.shared.handleQuestEvent(.enteredIndoor)
        AmbientSceneAudioController.shared.play(resource: "background_music_indoor", worldRoot: worldRoot)
        didCommit = true

        // 손님 NPC가 Idle/Walk을 시작하고 휠체어가 실제 바닥 높이로 정착할 짧은 여유를
        // 준 뒤에 화면을 밝힌다. 씬이 "짠" 하고 정적으로 나타나지 않게 하기 위함이다.
        try? await Task.sleep(for: .seconds(0.3))
        guard im.isCurrentTransition(token) else { return }
        SceneFadeOverlay.shared.fadeIn()
    }

    /// 모든 실패 가능 작업을 현재 장면과 분리된 엔티티에서 끝낸다.
    private static func prepareIndoorScene() async throws -> PreparedIndoorScene {
        let visible = try await Entity(named: "Indoor", in: realityKitContentBundle)
        try Task.checkCancellation()
        let collision = visible.clone(recursive: true)
        // prepareVisible이 콜리전 이름 메시의 ModelComponent를 지우면 visualBounds를
        // 더는 잴 수 없다 — 그 전에 캡처한다. visible이 아직 worldRoot에 안 붙어
        // 있어 여기선 visible 자신 기준으로만 담아 두고, 최종 worldRoot 좌표 변환은
        // 나중에(NPCGuestCoordinator.enterIndoor, worldRoot에 붙은 뒤) 한다.
        let collisionCubeAreas = SceneEntityPreparation.captureAreas(
            named: indoorCollisionCubeNames, in: visible, relativeTo: visible)
        SceneEntityPreparation.prepareVisible(visible)
        let collisionShapeCount = await SceneEntityPreparation.prepareCollision(collision)
        try Task.checkCancellation()
        let smoothie = try? await Entity(
            named: ImmersiveSceneCatalog.rainbowSmoothie,
            in: realityKitContentBundle)
        try Task.checkCancellation()
        let waypoint = try? await Entity(
            named: ImmersiveSceneCatalog.wayPoint,
            in: realityKitContentBundle)
        try Task.checkCancellation()
        // 손님 테이블에 무작위로 얹을 디저트 템플릿. 씬(Indoor.usda)에는 배치돼 있지 않고
        // rkassets 카탈로그의 독립 에셋이라 RainbowSmoothie/WayPoint와 같은 방식으로 이름으로
        // 직접 불러온다 — 못 불러와도(nil) 손님 착석 자체는 그대로 진행된다.
        let cake = try? await Entity(named: ImmersiveSceneCatalog.cake, in: realityKitContentBundle)
        try Task.checkCancellation()
        let latte = try? await Entity(named: ImmersiveSceneCatalog.latte, in: realityKitContentBundle)
        try Task.checkCancellation()

        // Indoor에 아직 collision 네이밍 메시가 없으면 0개일 수 있다. 씬에 상주하는
        // 공통 바닥 충돌이 접지를 담당하며, 실내 벽 콜리전은 별도 에셋 작업 대상이다.
        return PreparedIndoorScene(visible: visible,
                                   collision: collision,
                                   collisionShapeCount: collisionShapeCount,
                                   smoothie: smoothie,
                                   waypoint: waypoint,
                                   cake: cake,
                                   latte: latte,
                                   collisionCubeAreas: collisionCubeAreas)
    }

    /// 비활성 상태로 worldRoot에 연결된 Indoor 엔티티에서 트리거와 스폰 포즈를 계산한다.
    private static func resolveIndoorLayout(in indoorVisible: Entity,
                                            relativeTo worldRoot: Entity) -> IndoorLayout {
        var kioskCenter = InteractionTuning.kioskFallbackCenter
        if let kiosk = indoorVisible.findEntity(named: "Kiosk") {
            let bounds = kiosk.visualBounds(relativeTo: worldRoot)
            kioskCenter = SIMD2(bounds.center.x, bounds.center.z)
        }

        var spawn = SIMD2<Float>(InteractionTuning.indoorSpawnX,
                                 InteractionTuning.indoorSpawnZ)
        var heading = InteractionTuning.indoorSpawnHeading
        if let door = indoorVisible.findEntity(named: "Door") {
            let bounds = door.visualBounds(relativeTo: worldRoot)
            let doorCenter = SIMD2<Float>(bounds.center.x, bounds.center.z)
            let delta = kioskCenter - doorCenter
            if simd_length(delta) > 0.001 {
                let towardCafe = simd_normalize(delta)
                spawn = doorCenter + towardCafe * InteractionTuning.indoorSpawnDistanceFromDoor
                // 휠체어의 로컬 정면은 -Z.
                heading = atan2(-towardCafe.x, -towardCafe.y)
            }
        }
        return IndoorLayout(kioskCenter: kioskCenter, spawn: spawn, heading: heading)
    }
}
