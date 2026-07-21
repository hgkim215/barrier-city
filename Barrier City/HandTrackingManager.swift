import ARKit
import RealityKit
import simd

/// 실기(Vision Pro)용 손 추적.
/// 손가락을 말아 쥐면 '잡힘'으로 인식하고, 잡은 손을 앞뒤로 미는 양을
/// 해당 쪽 바퀴 입력(leftInput/rightInput)으로 변환한다.
///
/// 주의: ARKit 손 추적은 Full Immersive Space에서만 동작하며,
/// 시뮬레이터에서는 데이터가 없다(그래서 디버그 입력을 별도로 둠).
@MainActor
final class HandTrackingManager {

    private let session = ARKitSession()
    private let provider = HandTrackingProvider()
    private var running = false

    /// 손 속도 → 바퀴 속도 배율(1.0=손 속도 그대로 1:1, 작을수록 바퀴에 힘 덜 들어감). 미세조정용.
    private static let gripSpeedScale: Float = 0.7
    /// 손(밀기) 속도 상한(m/s). 손 추적이 한 번 튀어도 비현실적 속도로 안 잡히게 컷.
    /// 내리막 가속(중력)은 이와 무관 — 이건 '미는 속도'에만 적용된다.
    private static let maxHandSpeed: Float = 2.0

    // 직전 프레임의 손 Z 위치와 시각(손 속도 계산용)
    private var lastZ: [HandAnchor.Chirality: Float] = [:]
    private var lastTime: [HandAnchor.Chirality: TimeInterval] = [:]

    // 래치된 잡힘 상태(주먹 펴기 전까지 유지)
    private var latched: [HandAnchor.Chirality: Bool] = [:]

    func start(model: AppModel) async {
        // 지원 여부 확인(시뮬레이터/미지원 기기에서 바로 빠져나감)
        guard HandTrackingProvider.isSupported else {
            print("HandTracking 미지원 환경 — 손 추적 건너뜀")
            return
        }

        // 권한을 '먼저' 명시적으로 요청한다.
        // Info.plist에 NSHandsTrackingUsageDescription이 없으면 여기서 실패하므로
        // run() 호출 전에 안전하게 거른다(없으면 OS가 앱을 강제종료시키는 것을 방지).
        let auth = await session.requestAuthorization(for: [.handTracking])
        guard auth[.handTracking] == .allowed else {
            print("HandTracking 권한 거부/불가 — 손 추적 비활성화 (Info.plist 키 확인)")
            return
        }

        do {
            try await session.run([provider])
            running = true
        } catch {
            print("HandTracking 시작 실패: \(error)")
            return
        }

        for await update in provider.anchorUpdates {
            guard running else { break }
            let anchor = update.anchor
            model.handUpdates += 1            // 데이터가 들어오는지 확인용(추적 전이라도 증가)
            if anchor.isTracked { model.handTracked += 1 }
            if anchor.handSkeleton != nil { model.handSkeletonOK += 1 }
            // isTracked가 false여도 골격이 있으면 측정은 시도(어디서 끊기는지 보려고).
            process(anchor, model: model)
        }
    }

    func stop() {
        running = false
        session.stop()
    }

    // MARK: - 처리

    /// 잡힘 판정 임계값(이 값보다 크면 '잡음'). 실기 보정용.
    /// 잡기 시작 임계값(이보다 세게 쥐면 '주먹'). 오잡힘 방지를 위해 높임.
    private static let grabThreshold: Float = 0.78
    /// 잡기 해제 임계값(이보다 펴면 '놓음'). 히스테리시스로 떨림 방지.
    private static let releaseThreshold: Float = 0.6

    private func process(_ anchor: HandAnchor, model: AppModel) {
        let chirality = anchor.chirality
        let (strength, rawD) = grabStrength(anchor)

        // 잡기 기준점: 손목이 아니라 '손바닥(중지 밑마디)' 월드 위치.
        // 손목은 실제 쥐는 지점보다 아래에 있어 잡기 영역이 처지므로 보정.
        let gripPos = gripWorldPosition(anchor)
        // 리치 판정용 월드 좌표 기록(추적이 끊기면 nil로 지워 오판 방지).
        switch chirality {
        case .left:  model.handWorldLeft  = anchor.isTracked ? gripPos : nil
        case .right: model.handWorldRight = anchor.isTracked ? gripPos : nil
        }
        let z = gripPos.z

        // 해당 쪽 바퀴까지 거리.
        let wheelPos = (chirality == .left) ? AppModel.leftWheelPos : AppModel.rightWheelPos
        let dist = simd_distance(gripPos, wheelPos)
        let nearWheel = dist < AppModel.grabRadius

        // 래치 잡기:
        //  - 아직 안 잡힌 상태: 주먹(>grabThreshold) + 바퀴 근처 → 잡기 시작
        //  - 이미 잡힌 상태: 손을 펴기(<releaseThreshold) 전까지 거리와 무관하게 유지
        var grabbing = latched[chirality] ?? false
        if grabbing {
            if strength < Self.releaseThreshold { grabbing = false }
        } else {
            if strength > Self.grabThreshold && nearWheel { grabbing = true }
        }
        latched[chirality] = grabbing

        // 진단 기록.
        switch chirality {
        case .left:  model.leftGrabStrength = strength;  model.leftRawD = rawD; model.leftWheelDist = dist
        case .right: model.rightGrabStrength = strength; model.rightRawD = rawD; model.rightWheelDist = dist
        }

        // 잡은 손의 '현재 전진 속도(m/s)' = z 이동량 / 경과시간.
        // (앞으로 밀면 z 감소 → +). 이 값으로 잡은 바퀴를 손에 1:1 고정한다.
        // 손을 떼는 순간의 속도가 바퀴에 남아 관성으로 굴러간다(System에서 처리).
        let now = ProcessInfo.processInfo.systemUptime
        var handVel: Float = 0
        if let prevZ = lastZ[chirality], let prevT = lastTime[chirality] {
            let dtHand = Float(now - prevT)
            if dtHand > 0.0001 {
                var raw = (prevZ - z) / dtHand * Self.gripSpeedScale
                // 추적 튐으로 인한 비현실적 스파이크 컷('미는 속도'만 제한, 내리막 중력과 무관).
                raw = max(-Self.maxHandSpeed, min(Self.maxHandSpeed, raw))
                // 저역통과로 떨림 완화.
                let prevV = (chirality == .left) ? model.handSpeedLeft : model.handSpeedRight
                handVel = prevV + (raw - prevV) * 0.5
            }
        }
        lastZ[chirality] = z
        lastTime[chirality] = now

        switch chirality {
        case .left:
            model.leftGrabbed = grabbing
            model.handSpeedLeft = grabbing ? handVel : 0
        case .right:
            model.rightGrabbed = grabbing
            model.handSpeedRight = grabbing ? handVel : 0
        }
    }

    /// 손바닥(중지 밑마디) 관절의 월드 위치. 잡기 기준점으로 사용.
    /// 골격이 없으면 손목(anchor 원점)으로 대체.
    private func gripWorldPosition(_ anchor: HandAnchor) -> SIMD3<Float> {
        let origin = anchor.originFromAnchorTransform
        if let skeleton = anchor.handSkeleton {
            let joint = skeleton.joint(.middleFingerKnuckle).anchorFromJointTransform
            let world = origin * joint
            let c = world.columns.3
            return SIMD3<Float>(c.x, c.y, c.z)
        }
        let c = origin.columns.3
        return SIMD3<Float>(c.x, c.y, c.z)
    }

    /// 쥠 정도와 원시 거리값을 함께 반환.
    /// - strength: 0=편 손, 1=주먹 (보정된 값)
    /// - rawD: 손가락끝-손목 평균거리 / 손크기 (펴면 큼, 주먹이면 작음). 보정 기준값.
    private func grabStrength(_ anchor: HandAnchor) -> (strength: Float, rawD: Float) {
        guard let skeleton = anchor.handSkeleton else { return (0, 0) }

        let wrist = skeleton.joint(.wrist).anchorFromJointTransform.columns.3.xyz
        let tips: [HandSkeleton.JointName] = [
            .indexFingerTip, .middleFingerTip, .ringFingerTip, .littleFingerTip
        ]
        // 손 크기 기준(손목→중지 밑동)으로 정규화
        let mid = skeleton.joint(.middleFingerMetacarpal).anchorFromJointTransform.columns.3.xyz
        let handSize = max(0.02, simd_distance(wrist, mid))

        var sumD: Float = 0
        for tip in tips {
            let p = skeleton.joint(tip).anchorFromJointTransform.columns.3.xyz
            sumD += simd_distance(wrist, p) / handSize
        }
        let rawD = sumD / Float(tips.count)

        // rawD를 0~1 쥠 세기로 매핑. (실기 보정 후 상수 조정)
        // 펴진 손 ≈ openD, 주먹 ≈ fistD 라고 보고 선형 보간.
        let openD: Float = 6.0   // 이 이상이면 완전히 편 손 (실측 ≈ 7)
        let fistD: Float = 3.5   // 이 이하이면 완전 주먹 (실측 ≈ 3)
        let strength = max(0, min(1, (openD - rawD) / (openD - fistD)))
        return (strength, rawD)
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
