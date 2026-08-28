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
    /// 진입 직후 한 번만 확정하는 기준 눈높이(m).
    /// 매 프레임 head를 따라가면 고개를 숙일 때마다 패널이 같이 내려가서,
    /// 앉은 자세 기준 높이를 한 번 정해 고정한다. 문 진입 패널도 이 값을 쓴다.
    private(set) var baselineEyeHeight: Float?

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

    /// 매 프레임 호출. 실제 배치는 placement가 바뀔 때 한 번만 일어난다.
    /// 영상 패널은 멀리 눈높이에 세워 yaw만 맞춘다.
    /// - panel: 텍스트 카드("questHUD") 엔티티.
    /// - videoPanel: 안내 영상("guideVideo") 엔티티. 없으면 무시한다.
    func update(panel: Entity,
                videoPanel: Entity?,
                placement: GuidePlacement,
                showsVideo: Bool,
                model: AppModel) {
        if placement != lastPlacement {
            placed = false
            lastPlacement = placement
        }

        // 기준 눈높이는 처음 관측한 값 하나로 고정한다.
        if baselineEyeHeight == nil, let live = liveHeadFrame() {
            baselineEyeHeight = live.position.y
            if wasUsingFallback {
                wasUsingFallback = false
                model.worldTrackingStatus = "추적 복구"
            }
        } else if baselineEyeHeight == nil, !wasUsingFallback {
            wasUsingFallback = true
            model.worldTrackingFallbacks += 1
            model.worldTrackingStatus = "추적 대기 · 고정 배치"
        }

        // 배치는 head가 아니라 씬 원점 기준 고정 좌표를 쓴다.
        //
        // 예전에는 head의 yaw로 forward/right를 잡아서, 패널이 놓이는 순간
        // 사용자가 왼쪽을 보고 있으면 왼쪽에, 고개를 숙이고 있으면 더 아래에
        // 생성됐다. 앉아서 하는 체험이고 이동은 worldRoot가 움직여 처리하므로
        // 사용자는 늘 씬 원점 근처에 있다. 따라서 정면을 씬의 -Z로 고정하면
        // 시선과 무관하게 항상 같은 자리에 뜬다.
        let eyeHeight = baselineEyeHeight ?? QuestTuning.seatedEyeHeightFallback
        let origin = SIMD3<Float>(0, eyeHeight, 0)
        let forward = SIMD3<Float>(0, 0, -1)
        let right = SIMD3<Float>(1, 0, 0)

        // MARK: 텍스트 카드
        let cardTarget: SIMD3<Float>
        let cardTilts: Bool
        switch placement {
        case .centerModal:
            // 손 닿는 거리에 낮게. 아래에서 시선각만큼 눕혀 책상 위 패널처럼 둔다.
            cardTarget = origin
                + forward * QuestTuning.cardDistance
                + SIMD3(0, QuestTuning.cardVerticalOffset, 0)
            cardTilts = true
        case .upperLeadingHUD:
            cardTarget = origin
                + forward * QuestTuning.forwardDistance
                + right * QuestTuning.hudLateralOffset
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
            placed = true
            panel.setPosition(cardTarget, relativeTo: nil)
            panel.setOrientation(
                facingOrientation(from: cardTarget, toward: origin, tilts: cardTilts),
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

        let videoPosition = origin
            + forward * QuestTuning.videoDistance
            + SIMD3(0, QuestTuning.videoVerticalOffset, 0)
        videoPanel.setPosition(videoPosition, relativeTo: nil)
        videoPanel.setOrientation(
            facingOrientation(from: videoPosition, toward: origin, tilts: false),
            relativeTo: nil)
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
        baselineEyeHeight = nil
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
private func normalizeSafe(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let l = simd_length(v)
    return l > 1e-5 ? v / l : SIMD3(0, 0, -1)
}
