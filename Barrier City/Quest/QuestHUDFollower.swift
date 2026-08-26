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
    private var placed = false        // 최초 1회는 스무딩 없이 즉시 배치
    private var videoPlaced = false
    private var runGeneration = 0
    private var wasUsingFallback = false
    private var lastPlacement: GuidePlacement?
    /// 문 진입 패널 등 다른 UI가 온보딩과 같은 높이를 쓰도록 마지막 head 위치를 공유한다.
    private(set) var lastHeadPosition: SIMD3<Float>?

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

    /// 매 프레임 호출. 카드는 head 기준 타깃으로 스무딩 이동 + 빌보드,
    /// 영상 패널은 멀리 눈높이에 세워 yaw만 맞춘다.
    /// - panel: 텍스트 카드("questHUD") 엔티티.
    /// - videoPanel: 안내 영상("guideVideo") 엔티티. 없으면 무시한다.
    /// - dt: 이전 프레임과의 시간 간격(초).
    func update(panel: Entity,
                videoPanel: Entity?,
                dt: Float,
                placement: GuidePlacement,
                showsVideo: Bool,
                model: AppModel) {
        if placement != lastPlacement {
            placed = false
            lastPlacement = placement
        }

        let frame: HeadFrame
        if let live = liveHeadFrame() {
            if wasUsingFallback {
                wasUsingFallback = false
                model.worldTrackingStatus = "추적 복구"
            }
            frame = live
        } else {
            if !wasUsingFallback {
                wasUsingFallback = true
                model.worldTrackingFallbacks += 1
                model.worldTrackingStatus = "추적 유실 · 고정 배치"
            }
            frame = HeadFrame(position: SIMD3(0, 1.5, 0),
                              forward: SIMD3(0, 0, -1),
                              right: SIMD3(1, 0, 0))
        }
        lastHeadPosition = frame.position

        // MARK: 텍스트 카드
        let cardTarget: SIMD3<Float>
        let cardTilts: Bool
        switch placement {
        case .centerModal:
            // 손 닿는 거리에 낮게. 아래에서 시선각만큼 눕혀 책상 위 패널처럼 둔다.
            cardTarget = frame.position
                + frame.forward * QuestTuning.cardDistance
                + SIMD3(0, QuestTuning.cardVerticalOffset, 0)
            cardTilts = true
        case .upperLeadingHUD:
            cardTarget = frame.position
                + frame.forward * QuestTuning.forwardDistance
                + frame.right * QuestTuning.hudLateralOffset
                + SIMD3(0, QuestTuning.hudVerticalOffset, 0)
            cardTilts = false
        }

        // 카드는 영상 패널과 마찬가지로 한 번 놓고 그 자리에 고정한다.
        // 머리를 돌릴 때마다 따라오면 시선을 계속 잡아끌어 읽기도 주행도 불편하다.
        //
        // placement가 바뀔 때만 placed가 false로 풀리므로:
        //  - 인트로 → 튜토리얼 → 미션 안내는 모두 .centerModal이라 처음 놓인
        //    자리를 그대로 유지한다.
        //  - 미션이 시작되면 .upperLeadingHUD로 바뀌며 그 순간의 좌측 상단에
        //    다시 배치되고, 다음 미션 안내에서 또 한 번 정면에 배치된다.
        if !placed {
            let cardPosition = smoothed(current: panel.position(relativeTo: nil),
                                        target: cardTarget,
                                        head: frame.position,
                                        dt: dt,
                                        placed: &placed)
            panel.setPosition(cardPosition, relativeTo: nil)
            panel.setOrientation(
                facingOrientation(from: cardPosition, toward: frame.position, tilts: cardTilts),
                relativeTo: nil)
        }

        // MARK: 영상 패널
        guard let videoPanel else { return }
        if videoPanel.isEnabled != showsVideo {
            videoPanel.isEnabled = showsVideo
            if !showsVideo { videoPlaced = false }
        }
        guard showsVideo else { return }

        // 영상은 벽에 걸린 TV처럼 한 번 놓고 그 자리에 둔다. 머리를 따라오면
        // 화면이 계속 미끄러져 보기 불편하다. 튜토리얼을 벗어나 videoPlaced가
        // 풀리면 다음 진입 때 사용자 정면에 다시 배치된다.
        guard !videoPlaced else { return }
        videoPlaced = true

        let videoPosition = frame.position
            + frame.forward * QuestTuning.videoDistance
            + SIMD3(0, QuestTuning.videoVerticalOffset, 0)
        videoPanel.setPosition(videoPosition, relativeTo: nil)
        videoPanel.setOrientation(
            facingOrientation(from: videoPosition, toward: frame.position, tilts: false),
            relativeTo: nil)
    }

    /// 데드존 밖일 때만 지수 스무딩으로 따라간다. 최초 1회는 즉시 배치.
    private func smoothed(current: SIMD3<Float>,
                          target: SIMD3<Float>,
                          head: SIMD3<Float>,
                          dt: Float,
                          placed: inout Bool) -> SIMD3<Float> {
        guard placed else {
            placed = true
            return target
        }
        let angle = angleBetween(current - head, target - head)
        let distance = simd_distance(current, target)
        guard angle > QuestTuning.deadZoneAngle || distance > QuestTuning.deadZoneDistance else {
            return current
        }
        return current + (target - current) * (1 - exp(-QuestTuning.smoothingRate * dt))
    }

    /// head를 향하는 yaw 빌보드. tilts면 시선각만큼 눕혀 정면으로 마주 보게 한다.
    private func facingOrientation(from position: SIMD3<Float>,
                                   toward head: SIMD3<Float>,
                                   tilts: Bool) -> simd_quatf {
        let dir = head - position
        let horizontal = simd_length(SIMD3(dir.x, 0, dir.z))
        guard horizontal > 1e-5 else { return simd_quatf(angle: 0, axis: [0, 1, 0]) }

        let yaw = simd_quatf(angle: atan2(dir.x, dir.z), axis: [0, 1, 0])
        guard tilts else { return yaw }

        // 패널 normal은 로컬 +Z. 로컬 X축으로 -pitch 만큼 돌리면 위를 향한다.
        // 시선각을 그대로 쓰면 완전히 마주 보느라 지나치게 누워 보여서,
        // cardPitchRatio 만큼만 눕힌다.
        let pitch = min(atan2(dir.y, horizontal) * QuestTuning.cardPitchRatio,
                        QuestTuning.cardMaxPitch)
        return yaw * simd_quatf(angle: -pitch, axis: [1, 0, 0])
    }

    /// 세션 정리용.
    func stop() {
        runGeneration &+= 1
        stopped = true
        running = false
        placed = false
        videoPlaced = false
        lastPlacement = nil
        lastHeadPosition = nil
        wasUsingFallback = false
        session.stop()
    }

    /// head 위치와 수평면에 투영한 forward/right. 못 얻으면 nil.
    private func liveHeadFrame() -> HeadFrame? {
        guard running,
              let anchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        else { return nil }
        let m = anchor.originFromAnchorTransform
        return HeadFrame(
            position: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
            // head yaw만 사용(pitch/roll 무시).
            forward: normalizeSafe(-SIMD3(m.columns.2.x, 0, m.columns.2.z)),
            right: normalizeSafe(SIMD3(m.columns.0.x, 0, m.columns.0.z)))
    }
}

private struct HeadFrame {
    let position: SIMD3<Float>
    let forward: SIMD3<Float>
    let right: SIMD3<Float>
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
