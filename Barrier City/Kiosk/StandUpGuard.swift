//
//  StandUpGuard.swift
//  Barrier City
//
//  체험 중 사용자가 일어서면 "휠체어 사용자는 일어설 수 없습니다" 오버레이를 띄운다.
//  QuestHUDFollower처럼 자체 ARKitSession + WorldTrackingProvider로 head 높이를 조회
//  (한 앱에 세션 여러 개 허용). head 포즈를 못 얻으면 가드 비활성(fail-open).
//

import ARKit
import RealityKit
import QuartzCore
import simd

@MainActor
final class StandUpGuard {
    private let session = ARKitSession()
    private let provider = WorldTrackingProvider()
    private var running = false
    private var baselineY: Float?
    /// 오버레이 attachment 엔티티(씬 루트 자식). tick이 head 앞에 배치한다.
    var overlayEntity: Entity?

    func start() async {
        guard WorldTrackingProvider.isSupported else {
            print("WorldTracking 미지원 — 일어서기 가드 비활성")
            return
        }
        do {
            try await session.run([provider])
            running = true
        } catch {
            print("WorldTracking 시작 실패: \(error) — 일어서기 가드 비활성")
        }
    }

    /// 매 프레임(InteractionSetup.tick에서 호출). 기준 높이 캡처 → 판정 → 오버레이 배치.
    func tick() {
        guard running,
              let anchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        else { return }
        let m = anchor.originFromAnchorTransform
        let headY = m.columns.3.y
        if baselineY == nil { baselineY = headY }
        guard let base = baselineY else { return }

        let kfm = KioskFlowModel.shared
        kfm.standUpShown = KioskFlowLogic.standUpShown(
            currentlyShown: kfm.standUpShown, headY: headY, baselineY: base,
            enter: KioskTuning.standUpEnter, exit: KioskTuning.standUpExit)

        guard let overlay = overlayEntity else { return }
        overlay.isEnabled = kfm.standUpShown
        if kfm.standUpShown {
            // head 정면 1m, 눈높이에 배치 + head를 향해 yaw 빌보드.
            let head = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let forward = -SIMD3(m.columns.2.x, 0, m.columns.2.z)
            let f = simd_length(forward) > 1e-5 ? simd_normalize(forward) : SIMD3(0, 0, -1)
            let pos = head + f * 1.0
            overlay.setPosition(pos, relativeTo: nil)
            let dir = head - pos
            overlay.setOrientation(simd_quatf(angle: atan2(dir.x, dir.z), axis: [0, 1, 0]),
                                   relativeTo: nil)
        }
    }

    func stop() {
        running = false
        baselineY = nil
        session.stop()
    }
}
