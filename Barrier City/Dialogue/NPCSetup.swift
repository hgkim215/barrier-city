//
//  NPCSetup.swift
//  Barrier City
//
//  실내 카운터에 NPC 직원(Skull 모델)을 배치하고 애니메이션을 재생한다.
//  모델·프림·클립이 없어도 트리거와 대화는 동작한다(fail-open).
//

import Foundation
import RealityKit
import RealityKitContent
import simd

@MainActor
enum NPCSetup {

    private(set) static var staffEntity: Entity?

    /// Indoor 전환 시 호출. 카운터(Bar) 프림 위치(폴백: 상수)에 Skull을 놓고
    /// 배치한 맵 좌표(트리거 중심용)를 반환한다.
    static func placeStaff(in map: Entity, worldRoot: Entity) async -> SIMD2<Float> {
        var center = KioskTuning.npcFallbackCenter
        if let bar = map.findEntity(named: "Bar") {
            let b = bar.visualBounds(relativeTo: worldRoot)
            center = SIMD2(b.center.x, b.center.z)
            print("NPC 배치: Bar 프림 위치 사용 (\(b.center.x), \(b.center.z))")
        } else {
            print("⚠️ Bar 프림을 찾지 못해 NPC 폴백 좌표 사용: \(center)")
        }

        guard let staff = try? await Entity(named: "Skull", in: realityKitContentBundle) else {
            print("⚠️ Skull(NPC) 로드 실패 — 트리거만 등록")
            return center
        }
        staff.name = "npcStaff"
        staff.scale = SIMD3(repeating: KioskTuning.npcScale)
        staff.orientation = simd_quatf(angle: KioskTuning.npcYaw, axis: [0, 1, 0])
        staff.position = [center.x, 0, center.y]
        map.addChild(staff)   // 맵과 함께 움직인다(visibleMap은 worldRoot에 identity로 붙음)
        staffEntity = staff
        playAnimation(named: "Greeting")
        return center
    }

    /// 이름이 포함된 애니메이션 클립을 1회 재생. 없으면 첫 클립, 그것도 없으면 무시.
    static func playAnimation(named name: String) {
        guard let staff = staffEntity else { return }
        let anims = staff.availableAnimations
        let anim = anims.first { $0.name?.localizedCaseInsensitiveContains(name) == true }
            ?? anims.first
        guard let anim else { return }
        staff.playAnimation(anim, transitionDuration: 0.3)
    }

    /// 재진입 대비 정리(씬 전환·install 리셋에서 호출).
    static func reset() {
        staffEntity?.removeFromParent()
        staffEntity = nil
    }
}
