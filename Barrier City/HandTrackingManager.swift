import ARKit
import Foundation
import RealityKit
import simd

/// 실기(Vision Pro)용 손 추적.
/// 기본 모드는 손으로 각 바퀴를 잡아 미는 입력이고, 테스트 모드에서는
/// 주먹 하나를 가상 드론 스틱처럼 사용해 전진/회전 명령을 만든다.
///
/// 주의: ARKit 손 추적은 Full Immersive Space에서만 동작하며,
/// 시뮬레이터에서는 데이터가 없다(그래서 디버그 입력을 별도로 둠).
@MainActor
final class HandTrackingManager {

    private let session = ARKitSession()
    private let provider = HandTrackingProvider()
    private var running = false
    /// 빠른 OFF→ON 때 이전 anchorUpdates 루프가 되살아나는 것을 막는 세대 토큰.
    private var runGeneration = 0

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

    // 테스트용 주먹 드론 조작 상태
    private var processingTestMode: Bool?
    private var activeFistHand: HandAnchor.Chirality?
    private var fistNeutralPosition: SIMD3<Float>?
    private var captureArmed: [HandAnchor.Chirality: Bool] = [:]
    private var smoothedForward: Float = 0
    private var smoothedTurn: Float = 0
    private var lastFistSampleTime: TimeInterval = 0
    private var observedFistResetID = 0

    /// 손이 이 시간 이상 사라지면 주행을 즉시 끊는다.
    private static let staleFistTimeout: TimeInterval = 0.25
    /// 주먹 기준점 주변의 떨림을 무시하는 거리와 최대 입력 거리(m).
    private static let forwardDeadZone: Float = 0.04
    private static let forwardFullScale: Float = 0.24
    private static let turnDeadZone: Float = 0.035
    private static let turnFullScale: Float = 0.18
    /// 축 저역통과 응답 속도(약 100ms 시정수).
    private static let fistSmoothingRate: Float = 10

    func start(model: AppModel) async {
        runGeneration &+= 1
        let generation = runGeneration
        running = false
        resetAllTrackingState(allowImmediateFistCapture: true)

        // 지원 여부 확인(시뮬레이터/미지원 기기에서 바로 빠져나감)
        guard HandTrackingProvider.isSupported else {
            model.handTrackingStatus = "이 기기에서는 손 추적을 지원하지 않습니다"
            return
        }

        // 권한을 '먼저' 명시적으로 요청한다.
        // Info.plist에 NSHandsTrackingUsageDescription이 없으면 여기서 실패하므로
        // run() 호출 전에 안전하게 거른다(없으면 OS가 앱을 강제종료시키는 것을 방지).
        model.handTrackingStatus = "손 추적 권한 확인 중…"
        let auth = await session.requestAuthorization(for: [.handTracking])
        guard generation == runGeneration, !Task.isCancelled else { return }
        guard auth[.handTracking] == .allowed else {
            model.handTrackingStatus = "손 추적 권한이 필요합니다"
            return
        }

        do {
            try await session.run([provider])
            // generation이 다르면 더 최신 start/stop이 이미 세션 소유권을 가졌다.
            // 여기서 stop하면 새 세션까지 끊을 수 있으므로 조용히 폐기한다.
            guard generation == runGeneration else { return }
            guard !Task.isCancelled else {
                session.stop()
                return
            }
            running = true
        } catch {
            guard generation == runGeneration, !Task.isCancelled else { return }
            model.handTrackingStatus = "손 추적 시작 실패: \(error.localizedDescription)"
            return
        }

        model.handTrackingStatus = model.testFistDriveEnabled
            ? "주먹을 쥐면 그 위치가 중립점이 됩니다"
            : "손 추적 연결됨 · 바퀴를 잡아 미세요"

        defer {
            if generation == runGeneration { running = false }
        }

        for await update in provider.anchorUpdates {
            guard running, generation == runGeneration, !Task.isCancelled else { break }
            let anchor = update.anchor
            model.handUpdates += 1            // 데이터가 들어오는지 확인용(추적 전이라도 증가)
            if anchor.isTracked { model.handTracked += 1 }
            if anchor.handSkeleton != nil { model.handSkeletonOK += 1 }
            // isTracked가 false여도 골격이 있으면 측정은 시도(어디서 끊기는지 보려고).
            process(anchor, model: model)
        }

        if generation == runGeneration, running, !Task.isCancelled {
            running = false
            model.releaseWheelHandInput()
            model.stopFistDrive(
                requestRecenter: true,
                status: "손 추적 연결이 종료되었습니다 · 토글을 다시 켜 주세요")
        }
    }

    /// 이 뷰 인스턴스가 소유한 ARKit 자원만 종료한다.
    /// 이전 몰입 뷰의 늦은 종료에서도 새 세션의 AppModel 상태를 건드리지 않는다.
    func stopSession() {
        runGeneration &+= 1
        running = false
        session.stop()
        resetAllTrackingState(allowImmediateFistCapture: false)
    }

    /// 현재 몰입 세션 소유자만 호출해야 하는 공유 입력 상태 정리.
    func clearModelInput(model: AppModel) {
        model.releaseWheelHandInput()
        model.stopFistDrive(requestRecenter: true)
        model.handTrackingStatus = model.useHandTracking && !model.isImmersive
            ? "체험을 시작하면 손 추적을 연결합니다"
            : "꺼짐"
    }

    func stop(model: AppModel) {
        stopSession()
        clearModelInput(model: model)
    }

    // MARK: - 처리

    /// 잡힘 판정 임계값(이 값보다 크면 '잡음'). 실기 보정용.
    /// 잡기 시작 임계값(이보다 세게 쥐면 '주먹'). 오잡힘 방지를 위해 높임.
    private static let grabThreshold: Float = 0.78
    /// 잡기 해제 임계값(이보다 펴면 '놓음'). 히스테리시스로 떨림 방지.
    private static let releaseThreshold: Float = 0.6

    private func process(_ anchor: HandAnchor, model: AppModel) {
        // OFF 직후 이미 전달 대기 중이던 마지막 anchor가 입력을 되살리는 것을 막는다.
        guard model.useHandTracking else {
            model.releaseWheelHandInput()
            resetAllTrackingState(allowImmediateFistCapture: false)
            return
        }
        guard !GuideFlowModel.shared.isInteractionLocked else {
            model.discardGuideLockedInput()
            resetAllTrackingState(allowImmediateFistCapture: false)
            return
        }

        let chirality = anchor.chirality
        let (strength, rawD) = grabStrength(anchor)

        // 잡기 기준점: 손목이 아니라 '손바닥(중지 밑마디)' 월드 위치.
        // 손목은 실제 쥐는 지점보다 아래에 있어 잡기 영역이 처지므로 보정.
        let gripPos = gripWorldPosition(anchor)
        let kioskHandSide: KioskHandSide = chirality == .left ? .left : .right
        InteractionModel.shared.processKioskHandSample(
            side: kioskHandSide,
            worldPosition: gripPos,
            timestamp: ProcessInfo.processInfo.systemUptime,
            isTracked: anchor.isTracked)

        // 해당 쪽 바퀴까지 거리.
        let wheelPos = (chirality == .left) ? AppModel.leftWheelPos : AppModel.rightWheelPos
        let dist = simd_distance(gripPos, wheelPos)

        // 진단 기록.
        switch chirality {
        case .left:  model.leftGrabStrength = strength;  model.leftRawD = rawD; model.leftWheelDist = dist
        case .right: model.rightGrabStrength = strength; model.rightRawD = rawD; model.rightWheelDist = dist
        }

        synchronizeInputModeIfNeeded(model: model)

        if model.testFistDriveEnabled {
            processFistDrive(anchor,
                             strength: strength,
                             gripPosition: gripPos,
                             model: model)
            return
        }

        processWheelGrip(chirality: chirality,
                         strength: strength,
                         gripPosition: gripPos,
                         wheelDistance: dist,
                         model: model)
    }

    /// 테스트 모드와 실제 바퀴 잡기 모드가 같은 입력 필드를 동시에 쓰지 않도록 전환 시 정리한다.
    private func synchronizeInputModeIfNeeded(model: AppModel) {
        let isTestMode = model.testFistDriveEnabled
        if processingTestMode != isTestMode {
            model.releaseWheelHandInput()
            resetWheelGripState()
            // 토글 직전에 이미 쥐고 있던 손이 곧바로 운전하지 않게, 한 번 편 뒤 쥐어야 한다.
            resetFistController(allowImmediateCapture: false)
            processingTestMode = isTestMode
            observedFistResetID = model.fistDriveResetID
            if isTestMode {
                model.handTrackingStatus = "주먹을 쥐면 그 위치가 중립점이 됩니다"
            }
        }

        // 재시작·외부 안전 정지 뒤에는 한 번 손을 편 다음 다시 쥐어야 새 중립점을 잡는다.
        if isTestMode, observedFistResetID != model.fistDriveResetID {
            resetFistController(allowImmediateCapture: false)
            observedFistResetID = model.fistDriveResetID
        }
    }

    // MARK: 실제 바퀴 잡기

    private func processWheelGrip(chirality: HandAnchor.Chirality,
                                  strength: Float,
                                  gripPosition: SIMD3<Float>,
                                  wheelDistance: Float,
                                  model: AppModel) {
        let z = gripPosition.z
        let nearWheel = wheelDistance < AppModel.grabRadius

        // 래치 잡기:
        //  - 아직 안 잡힌 상태: 주먹(>grabThreshold) + 바퀴 근처 → 잡기 시작
        //  - 이미 잡힌 상태: 손을 펴기(<releaseThreshold) 전까지 거리와 무관하게 유지
        var grabbing = latched[chirality] ?? false
        if grabbing {
            if strength < Self.releaseThreshold { grabbing = false }
        } else if strength > Self.grabThreshold && nearWheel {
            grabbing = true
        }
        latched[chirality] = grabbing

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

    // MARK: 테스트용 주먹 드론 조작

    private func processFistDrive(_ anchor: HandAnchor,
                                  strength: Float,
                                  gripPosition: SIMD3<Float>,
                                  model: AppModel) {
        let chirality = anchor.chirality
        let now = ProcessInfo.processInfo.systemUptime

        // 조작 손만 사라지고 다른 손 업데이트만 오는 경우에도 소유권과 주행을 해제한다.
        if activeFistHand != nil,
           lastFistSampleTime > 0,
           now - lastFistSampleTime > Self.staleFistTimeout {
            releaseFistController(model: model,
                                  ownerCanCaptureAgain: false,
                                  status: "손 추적이 끊겼습니다 · 손을 펴고 다시 쥐세요")
        }

        let hasUsableTracking = anchor.isTracked && anchor.handSkeleton != nil
        guard hasUsableTracking else {
            captureArmed[chirality] = false
            if activeFistHand == chirality {
                releaseFistController(model: model,
                                      ownerCanCaptureAgain: false,
                                      status: "손 추적이 끊겼습니다 · 손을 펴고 다시 쥐세요")
            }
            return
        }

        // 손을 충분히 펴야 다음 주먹이 새로운 중립점으로 보정된다.
        if strength < Self.releaseThreshold {
            captureArmed[chirality] = true
            if activeFistHand == chirality {
                releaseFistController(model: model,
                                      ownerCanCaptureAgain: true,
                                      status: "정지 · 다시 주먹을 쥐면 중립점이 설정됩니다")
            }
            return
        }

        if strength > Self.grabThreshold {
            let wasArmed = captureArmed[chirality] ?? true
            captureArmed[chirality] = false

            if activeFistHand == nil, wasArmed {
                activeFistHand = chirality
                fistNeutralPosition = gripPosition
                smoothedForward = 0
                smoothedTurn = 0
                lastFistSampleTime = now
                model.updateFistDrive(forwardAxis: 0,
                                      turnAxis: 0,
                                      hand: handName(chirality),
                                      timestamp: now)
                return
            }
        }

        // 먼저 잡은 한 손만 운전한다. 다른 손 업데이트는 출력을 덮어쓰지 않는다.
        guard activeFistHand == chirality, let neutral = fistNeutralPosition else { return }

        let rawForward = positiveAxis(neutral.z - gripPosition.z,
                                      deadZone: Self.forwardDeadZone,
                                      fullScale: Self.forwardFullScale)
        let rawTurn = signedAxis(gripPosition.x - neutral.x,
                                 deadZone: Self.turnDeadZone,
                                 fullScale: Self.turnFullScale)

        let dt = Float(max(0, min(0.1, now - lastFistSampleTime)))
        let alpha = dt > 0
            ? Float(1 - Foundation.exp(Double(-Self.fistSmoothingRate * dt)))
            : 1
        smoothedForward += (rawForward - smoothedForward) * alpha
        smoothedTurn += (rawTurn - smoothedTurn) * alpha
        lastFistSampleTime = now

        model.updateFistDrive(forwardAxis: smoothedForward,
                              turnAxis: smoothedTurn,
                              hand: handName(chirality),
                              timestamp: now)
    }

    private func releaseFistController(model: AppModel,
                                       ownerCanCaptureAgain: Bool,
                                       status: String) {
        if let owner = activeFistHand {
            captureArmed[owner] = ownerCanCaptureAgain
        }
        activeFistHand = nil
        fistNeutralPosition = nil
        smoothedForward = 0
        smoothedTurn = 0
        lastFistSampleTime = 0
        model.stopFistDrive(requestRecenter: false, status: status)
    }

    private func positiveAxis(_ distance: Float, deadZone: Float, fullScale: Float) -> Float {
        max(0, min(1, (distance - deadZone) / max(0.001, fullScale - deadZone)))
    }

    private func signedAxis(_ distance: Float, deadZone: Float, fullScale: Float) -> Float {
        let magnitude = abs(distance)
        guard magnitude > deadZone else { return 0 }
        let normalized = min(1, (magnitude - deadZone) / max(0.001, fullScale - deadZone))
        return distance < 0 ? -normalized : normalized
    }

    private func handName(_ chirality: HandAnchor.Chirality) -> String {
        chirality == .left ? "왼손" : "오른손"
    }

    private func resetWheelGripState() {
        lastZ.removeAll()
        lastTime.removeAll()
        latched.removeAll()
    }

    private func resetFistController(allowImmediateCapture: Bool) {
        activeFistHand = nil
        fistNeutralPosition = nil
        captureArmed = [
            .left: allowImmediateCapture,
            .right: allowImmediateCapture
        ]
        smoothedForward = 0
        smoothedTurn = 0
        lastFistSampleTime = 0
    }

    private func resetAllTrackingState(allowImmediateFistCapture: Bool) {
        processingTestMode = nil
        resetWheelGripState()
        resetFistController(allowImmediateCapture: allowImmediateFistCapture)
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
