//
//  QuestHUDFollower.swift
//  Barrier City
//
//  퀘스트 HUD를 사용자 머리 옆에 부드럽게 따라오게 둔다(lazy-follow).
//  자체 ARKitSession + WorldTrackingProvider로 head 포즈를 조회한다
//  (HandTrackingManager의 세션과 독립 — 한 앱에 세션 여러 개 허용).
//  head 포즈를 못 얻으면(예: 미지원) 씬 원점 앞 고정 배치로 폴백한다.
//

import ARKit
import RealityKit
import QuartzCore
import simd

@MainActor
final class QuestHUDFollower {
    private let session = ARKitSession()
    private let provider = WorldTrackingProvider()
    private var running = false
    private var stopped = false
    private var placed = false   // 최초 1회는 스무딩 없이 즉시 배치
    private var runGeneration = 0
    private var wasUsingFallback = false
    private var lastPlacement: GuidePlacement?

    /// world tracking 시작. 실패하면 running=false로 남아 update가 폴백 배치를 쓴다.
    func start(model: AppModel) async {
        guard !stopped else { return }
        runGeneration &+= 1
        let generation = runGeneration
        running = false
        model.worldTrackingStatus = "연결 중"
        guard WorldTrackingProvider.isSupported else {
            model.worldTrackingStatus = "미지원 · 고정 배치"
            model.worldTrackingFallbacks += 1
            wasUsingFallback = true
            return
        }
        do {
            try await session.run([provider])
            guard generation == runGeneration, !Task.isCancelled, !stopped else {
                session.stop()
                return
            }
            running = true
            model.worldTrackingStatus = "연결됨"
        } catch {
            guard generation == runGeneration, !Task.isCancelled, !stopped else { return }
            model.worldTrackingStatus = "시작 실패 · 고정 배치"
            model.worldTrackingFallbacks += 1
            wasUsingFallback = true
        }
    }

    /// 매 프레임 호출. panel을 head 옆 타깃으로 스무딩 이동 + head를 향해 yaw 빌보드.
    /// - panel: 씬 루트에 붙은 HUD 엔티티(월드 좌표계에서 움직인다).
    /// - dt: 이전 프레임과의 시간 간격(초, SceneEvents.Update.deltaTime).
    func update(panel: Entity,
                dt: Float,
                placement: GuidePlacement,
                model: AppModel) {
        if placement != lastPlacement {
            placed = false
            lastPlacement = placement
        }

        let targetPos: SIMD3<Float>
        let headPos: SIMD3<Float>
        if let pose = targetPose(placement: placement) {
            if wasUsingFallback {
                wasUsingFallback = false
                model.worldTrackingStatus = "추적 복구"
            }
            targetPos = pose.position
            headPos = pose.head
        } else {
            if !wasUsingFallback {
                wasUsingFallback = true
                model.worldTrackingFallbacks += 1
                model.worldTrackingStatus = "추적 유실 · 고정 배치"
            }
            targetPos = placement == .centerModal
                ? QuestTuning.centerFallbackPosition : QuestTuning.hudFallbackPosition
            headPos = SIMD3(0, targetPos.y, 0)   // 원점을 향함
        }

        let current = panel.position(relativeTo: nil)
        var newPos: SIMD3<Float>
        if !placed {
            newPos = targetPos          // 최초 즉시 배치
            placed = true
        } else {
            // 데드존: head 기준 두 방향 사잇각 + 거리로 판정.
            let angle = angleBetween(current - headPos, targetPos - headPos)
            let dist = simd_distance(current, targetPos)
            if angle > QuestTuning.deadZoneAngle || dist > QuestTuning.deadZoneDistance {
                let t = 1 - exp(-QuestTuning.smoothingRate * dt)   // 지수 스무딩
                newPos = current + (targetPos - current) * t
            } else {
                newPos = current
            }
        }
        panel.setPosition(newPos, relativeTo: nil)

        // 빌보드: head를 향해 yaw만(InteractionSetup 관례: yaw = atan2(dir.x, dir.z)).
        let dir = SIMD3(headPos.x - newPos.x, 0, headPos.z - newPos.z)
        if simd_length(dir) > 1e-5 {
            panel.setOrientation(simd_quatf(angle: atan2(dir.x, dir.z), axis: [0, 1, 0]),
                                 relativeTo: nil)
        }
    }

    /// 세션 정리용.
    func stop() {
        runGeneration &+= 1
        stopped = true
        running = false
        placed = false
        lastPlacement = nil
        wasUsingFallback = false
        session.stop()
    }

    /// head 포즈로부터 (타깃 위치, head 위치)를 계산. 못 얻으면 nil.
    private func targetPose(placement: GuidePlacement) -> (position: SIMD3<Float>, head: SIMD3<Float>)? {
        guard running,
              let anchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        else { return nil }
        let m = anchor.originFromAnchorTransform
        let head = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        // head yaw만 사용(pitch/roll 무시): forward(-Z)/right(+X)를 수평면에 투영.
        let forward = normalizeSafe(-SIMD3(m.columns.2.x, 0, m.columns.2.z))
        let right = normalizeSafe(SIMD3(m.columns.0.x, 0, m.columns.0.z))
        let lateral = placement == .centerModal
            ? QuestTuning.centerLateralOffset : QuestTuning.hudLateralOffset
        let vertical = placement == .centerModal
            ? QuestTuning.centerVerticalOffset : QuestTuning.hudVerticalOffset
        let pos = head
            + forward * QuestTuning.forwardDistance
            + right * lateral
            + SIMD3(0, vertical, 0)
        return (pos, head)
    }
}

// MARK: - simd 헬퍼
private func angleBetween(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let la = simd_length(a), lb = simd_length(b)
    guard la > 1e-5, lb > 1e-5 else { return 0 }
    return acos(max(-1, min(1, simd_dot(a, b) / (la * lb))))
}
private func normalizeSafe(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let l = simd_length(v)
    return l > 1e-5 ? v / l : SIMD3(0, 0, -1)
}
