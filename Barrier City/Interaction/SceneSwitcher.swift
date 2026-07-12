//
//  SceneSwitcher.swift
//  Barrier City
//
//  Outdoor("Map") → Indoor("Indoor") 배경 전환.
//  같은 몰입 공간을 유지한 채 ① worldRoot의 시각 맵 교체 ② 씬 원점의 투명 콜리전
//  사본 교체 ③ 포즈를 실내 문 앞 스폰 상수로 리셋한다.
//
//  stripPhysics/addStaticCollision은 이윤서 ImmersiveView의 검증된 로더 유틸을
//  그대로 호출한다(중복 구현 방지, Task 5에서 private 제거).
//

import RealityKit
import RealityKitContent
import SwiftUI

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

        // 4) 포즈 리셋: 실내 문 앞(밖에서 문을 열고 들어온 위치)
        app.restart()
        app.posX = InteractionTuning.indoorSpawnX
        app.posZ = InteractionTuning.indoorSpawnZ
        app.heading = InteractionTuning.indoorSpawnHeading

        // 5) 인터랙션 상태 전환: 실내 트리거는 1차 스코프에 없음(Kiosk는 다음 단계)
        im.scene = .indoor
        im.triggers = []
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.transitionError = nil
        im.panelEntity?.isEnabled = false
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
