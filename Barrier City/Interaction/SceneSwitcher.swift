//
//  SceneSwitcher.swift
//  Barrier City
//
//  Outdoor("Map") → Indoor("Indoor") 배경 전환.
//  같은 몰입 공간을 유지한 채 ① worldRoot의 시각 맵 교체 ② 씬 원점의 투명 콜리전
//  사본 교체 ③ DOOR1→Kiosk 방향으로 실내 문 안쪽 포즈를 계산한다.
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

    /// "예" 선택 시 호출. Outdoor에서만 동작하며, 실패 시 Outdoor를 유지하고
    /// 패널에 안내 문구를 띄운다.
    static func switchToIndoor() async {
        let im = InteractionModel.shared
        guard !im.isTransitioning, im.scene == .outdoor,
              let app = AppModel.current, let worldRoot = app.worldRoot else { return }
        im.isTransitioning = true
        defer { im.isTransitioning = false }

        // 1) 실내 시각 맵 로드(실패 시 전환 취소, Outdoor 유지)
        guard let indoorVisible = try? await Entity(named: "Indoor", in: realityKitContentBundle) else {
            im.transitionError = "지금은 들어갈 수 없어요. 잠시 후 다시 시도해 주세요."
            print("⚠️ Indoor 씬(시각) 로드 실패 — 이름/번들 확인")
            return
        }
        ImmersiveView.stripPhysics(indoorVisible)
        brighten(indoorVisible)

        // 2) 시각 맵 교체(worldRoot 아래)
        im.visibleMap?.removeFromParent()
        worldRoot.addChild(indoorVisible)
        im.visibleMap = indoorVisible

        // 3) 콜리전 사본 교체(기존 사본과 같은 부모에).
        //    Indoor에 아직 'collision' 네이밍 메시가 없으면 0개가 부여되지만,
        //    씬에 상주하는 debugFloorCollision이 바닥을 담당해 주행은 정상이다
        //    (실내 벽 통과는 1차 스코프에서 허용 — 김선환 RCP 콜리전 작업 대기).
        if let oldCollision = im.collisionMap, let parent = oldCollision.parent {
            if let indoorCollision = try? await Entity(named: "Indoor", in: realityKitContentBundle) {
                ImmersiveView.stripPhysics(indoorCollision)
                let n = await ImmersiveView.addStaticCollision(indoorCollision)
                app.collisionShapes = n
                indoorCollision.components.set(OpacityComponent(opacity: 0))
                parent.addChild(indoorCollision)
                oldCollision.removeFromParent()
                im.collisionMap = indoorCollision
            } else {
                print("⚠️ Indoor 씬(콜리전) 로드 실패 — 기존 콜리전 유지")
            }
        }

        // 4) Kiosk 프림의 맵 좌표(worldRoot 기준)를 찾고, 실패 시 폴백 상수를 쓴다.
        var kioskCenter = InteractionTuning.kioskFallbackCenter
        if let kiosk = indoorVisible.findEntity(named: "Kiosk") {
            // 트리거 중심은 엔티티 원점(pivot)이 아니라 '보이는 메시의 중심'(visualBounds)으로.
            // 메시가 pivot에서 벗어나 있으면 원점과 실제 키오스크 위치가 다르다.
            let b = kiosk.visualBounds(relativeTo: worldRoot)
            kioskCenter = SIMD2(b.center.x, b.center.z)
            print("키오스크 트리거 등록: (\(b.center.x), \(b.center.z))")
        } else {
            print("⚠️ Kiosk 프림을 찾지 못해 폴백 좌표 사용: \(kioskCenter)")
        }

        // 5) 포즈 리셋: DOOR1에서 Kiosk로 향하는 방향을 이용해 실제 문 안쪽에 스폰한다.
        //    이전 고정값 (0, 4)는 BarTable의 직원 구역과 겹쳐 NPC가 즉시 반응했다.
        var spawn = SIMD2<Float>(InteractionTuning.indoorSpawnX,
                                 InteractionTuning.indoorSpawnZ)
        var heading = InteractionTuning.indoorSpawnHeading
        if let door = indoorVisible.findEntity(named: "DOOR1") {
            let bounds = door.visualBounds(relativeTo: worldRoot)
            let doorCenter = SIMD2<Float>(bounds.center.x, bounds.center.z)
            let delta = kioskCenter - doorCenter
            if simd_length(delta) > 0.001 {
                let towardCafe = simd_normalize(delta)
                spawn = doorCenter + towardCafe * InteractionTuning.indoorSpawnDistanceFromDoor
                // 휠체어의 로컬 정면은 -Z.
                heading = atan2(-towardCafe.x, -towardCafe.y)
            }
            print("실내 스폰: (\(spawn.x), \(spawn.y)), heading=\(heading)")
        } else {
            print("⚠️ Indoor DOOR1을 찾지 못해 스폰 폴백 사용: \(spawn)")
        }
        app.restart()
        app.posX = spawn.x
        app.posZ = spawn.y
        app.heading = heading

        // 6) 인터랙션 상태 전환: 실내에는 키오스크 트리거를 등록한다.
        im.scene = .indoor
        im.triggers = [ProximityTrigger(
            id: "kiosk.order",
            center: kioskCenter,
            radius: InteractionTuning.kioskTriggerRadius,
            kind: .kioskScreen,
            prompt: InteractionTuning.kioskTitle)]
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.transitionError = nil
        im.kioskTooHighShown = false
        im.panelEntity?.isEnabled = false
        im.kioskPanelEntity?.isEnabled = false

        // 7) 점원 프로토타입 배치: Human/AreaK/BarTable marker와 애니메이션 씬을 연결한다.
        await app.npcClerk.enterIndoor(worldRoot: worldRoot,
                                       indoorMap: indoorVisible,
                                       kioskCenter: kioskCenter)

        // [김현기] 퀘스트: 실내(카페) 진입 완료 → 다음 단계로.
        QuestModel.shared.advance(on: .enteredIndoor)
    }

    /// Indoor 프로토타입의 검정 벽 임시 보정: 모든 메시를 밝은 단색으로 덮어쓴다.
    /// (wall 머티리얼에 diffuseColor가 없어 검정으로 렌더되는 이슈 — 텍스처링은
    ///  김선환 일정의 몫이므로 코드에서 임시 처리)
    /// 조상 이름을 물려받아 바닥/바/키오스크만 다른 톤을 준다.
    private static func brighten(_ entity: Entity, inheritedLabel: String = "") {
        let label = (inheritedLabel + " " + entity.name).lowercased()
        if var model = entity.components[ModelComponent.self] {
            let color: UIColor
            if label.contains("floor") {
                color = UIColor(white: 0.55, alpha: 1)          // 바닥: 중간 회색
            } else if label.contains("kiosk") {
                color = UIColor(white: 0.25, alpha: 1)          // 키오스크: 짙은 회색
            } else if label.contains("bar") {
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
