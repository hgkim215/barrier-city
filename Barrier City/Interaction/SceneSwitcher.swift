//
//  SceneSwitcher.swift
//  Barrier City
//
//  Outdoor("Outdoor") → Indoor("Indoor") 배경 전환.
//  같은 몰입 공간을 유지한 채 ① worldRoot의 시각 맵 교체 ② 씬 원점의 투명 콜리전
//  사본 교체 ③ Door→Kiosk 방향으로 실내 문 안쪽 포즈를 계산한다.
//
//  stripPhysics/addStaticCollision은 이윤서 ImmersiveView의 검증된 로더 유틸을
//  그대로 호출한다(중복 구현 방지, Task 5에서 private 제거).
//

import RealityKit
import RealityKitContent
import SwiftUI
import simd

@MainActor
enum SceneSwitcher {

    private struct PreparedIndoorScene {
        let visible: Entity
        let collision: Entity
        let collisionShapeCount: Int
    }

    private struct IndoorLayout {
        let kioskCenter: SIMD2<Float>
        let spawn: SIMD2<Float>
        let heading: Float
    }

    static func requestIndoorTransition() {
        let im = InteractionModel.shared
        im.startSceneTransition { token in
            await switchToIndoor(token: token)
        }
    }

    /// "예" 선택 시 호출. Outdoor에서만 동작하며, 실패 시 Outdoor를 유지하고
    /// 패널에 안내 문구를 띄운다.
    private static func switchToIndoor(token: SceneTransitionToken) async {
        let im = InteractionModel.shared
        guard im.isCurrentTransition(token), im.scene == .outdoor,
              let app = AppModel.current, let worldRoot = app.worldRoot else { return }

        // 1) 새 시각·콜리전 엔티티를 기존 장면 밖에서 모두 준비한다. 이 구간에서는
        //    현재 맵, 플레이어 포즈, 인터랙션 상태를 전혀 변경하지 않는다.
        let prepared: PreparedIndoorScene
        do {
            prepared = try await prepareIndoorScene()
        } catch is CancellationError {
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
        app.restart()
        app.motion.positionX = layout.spawn.x
        app.motion.positionZ = layout.spawn.y
        app.motion.heading = layout.heading
        app.motion.collisionShapeCount = prepared.collisionShapeCount

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
        im.kioskTooHighShown = false
        im.panelEntity?.isEnabled = false
        im.kioskPanelEntity?.isEnabled = false

        oldVisible.isEnabled = false
        oldCollision.isEnabled = false
        prepared.visible.isEnabled = true
        prepared.collision.isEnabled = true
        oldVisible.removeFromParent()
        oldCollision.removeFromParent()

        GuideFlowModel.shared.handleQuestEvent(.enteredIndoor)
    }

    /// 모든 실패 가능 작업을 현재 장면과 분리된 엔티티에서 끝낸다.
    private static func prepareIndoorScene() async throws -> PreparedIndoorScene {
        let visible = try await Entity(named: "Indoor", in: realityKitContentBundle)
        try Task.checkCancellation()
        ImmersiveView.stripPhysics(visible)
        ImmersiveView.hideColliders(visible)
        brighten(visible)

        let collision = try await Entity(named: "Indoor", in: realityKitContentBundle)
        try Task.checkCancellation()
        ImmersiveView.stripPhysics(collision)
        let collisionShapeCount = await ImmersiveView.addStaticCollision(collision)
        try Task.checkCancellation()
        ImmersiveView.stripRendering(collision)

        // Indoor에 아직 collision 네이밍 메시가 없으면 0개일 수 있다. 씬에 상주하는
        // debugFloorCollision이 바닥을 담당하며, 실내 벽 콜리전은 별도 에셋 작업 대상이다.
        return PreparedIndoorScene(visible: visible,
                                   collision: collision,
                                   collisionShapeCount: collisionShapeCount)
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

    /// Indoor 프로토타입의 검정 벽 임시 보정: 모든 메시를 밝은 단색으로 덮어쓴다.
    /// (wall 머티리얼에 diffuseColor가 없어 검정으로 렌더되는 이슈 — 텍스처링은
    ///  김선환 일정의 몫이므로 코드에서 임시 처리)
    /// 조상 이름을 물려받아 바닥/바/키오스크만 다른 톤을 준다.
    private static func brighten(_ entity: Entity, inheritedLabel: String = "") {
        let label = (inheritedLabel + " " + entity.name).lowercased()
        // 완성형 캐릭터의 PBR 머티리얼은 그대로 둔다. 이전의 `contains("bar")`는
        // Barista까지 바 가구로 오인해 캐릭터 전체를 나무색으로 덮어썼다.
        if label.contains("barista") { return }
        if var model = entity.components[ModelComponent.self] {
            let color: UIColor
            if label.contains("floor") {
                color = UIColor(white: 0.55, alpha: 1)          // 바닥: 중간 회색
            } else if label.contains("kiosk") {
                color = UIColor(white: 0.25, alpha: 1)          // 키오스크: 짙은 회색
            } else if label.contains("bartable") {
                color = UIColor(red: 0.45, green: 0.30, blue: 0.18, alpha: 1)  // 바: 나무톤
            } else {
                color = UIColor(white: 0.85, alpha: 1)          // 벽·천장: 밝은 회색
            }
            model.materials = [SimpleMaterial(color: color, isMetallic: false)]
            entity.components.set(model)
        }
        for child in entity.children {
            brighten(child, inheritedLabel: label)
        }
    }
}
