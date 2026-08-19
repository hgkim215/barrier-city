import Foundation
import Observation
import simd

/// 휠체어 물리 시뮬레이션의 프레임 간 상태와 저빈도 성능 진단을 소유한다.
/// AppModel은 사용자 입력과 앱 수명주기만 담당하고, MovementSystem은 이 객체만 갱신한다.
@Observable
@MainActor
final class WheelchairMotionState {
    var leftVelocity: Float = 0
    var rightVelocity: Float = 0
    var positionX: Float = 0
    var positionZ: Float = 0
    var heading: Float = 0

    var leftWheelAngle: Float = 0
    var rightWheelAngle: Float = 0

    var isBlocked = false
    var groundHeight: Float = 0
    var reachedGoal = false
    var collisionShapeCount = 0

    var pitch: Float = 0
    var roll: Float = 0
    var pitchVelocity: Float = 0
    var rollVelocity: Float = 0
    /// 지면 법선의 프레임 간 저역통과 결과. 5점 공간 평균만으로는 겹치는 콜라이더나
    /// 메시 이음매에서 매 프레임 다른 표면이 걸리는 시간축 떨림을 못 막아, 기울기가
    /// 그 노이즈를 그대로 따라가며 시야가 미세하게 떨렸다.
    var groundNormal: SIMD3<Float> = [0, 1, 0]

    var chairHeight: Float = 0
    var fallVelocity: Float = 0
    var bumpOffset: Float = 0
    var bumpVelocity: Float = 0
    var surgeOffset: Float = 0
    var surgeVelocity: Float = 0
    /// 지면 높이 격차(dy)가 stepBlock을 넘는 동안 bump 신호를 한 번만 내보내기 위한 래치.
    /// 격차가 한 프레임에 다 흡수되지 않으면 여러 프레임 동안 dy가 계속 임계값을 넘는데,
    /// 이 래치가 없으면 매 프레임 bump 사운드가 재발화돼 "덜덜덜"거리는 버즈음이 난다.
    var isBumpSettling = false

    var hasFallen = false
    var fallDirectionPitch: Float = 0
    var fallDirectionRoll: Float = 0

    var speed: Float = 0
    var headingDegrees: Float = 0
    var totalFrames: Int = 0
    var frameRate: Float = 0
    var frameTimeMilliseconds: Float = 0
    var physicsUpdateMilliseconds: Float = 0
    var raycastsPerFrame: Float = 0

    @ObservationIgnored private var diagnosticElapsed: Float = 0
    @ObservationIgnored private var diagnosticUpdateSeconds: Double = 0
    @ObservationIgnored private var diagnosticRaycasts = 0
    @ObservationIgnored private var diagnosticFrames = 0
    @ObservationIgnored private var accumulatedFrames = 0

    func reset() {
        leftVelocity = 0
        rightVelocity = 0
        positionX = 0
        positionZ = 0
        heading = 0
        leftWheelAngle = 0
        rightWheelAngle = 0
        isBlocked = false
        groundHeight = 0
        reachedGoal = false
        pitch = 0
        roll = 0
        pitchVelocity = 0
        rollVelocity = 0
        chairHeight = 0
        fallVelocity = 0
        bumpOffset = 0
        bumpVelocity = 0
        surgeOffset = 0
        surgeVelocity = 0
        isBumpSettling = false
        groundNormal = [0, 1, 0]
        hasFallen = false
        fallDirectionPitch = 0
        fallDirectionRoll = 0
        speed = 0
        headingDegrees = 0
        resetPerformanceDiagnostics()
    }

    /// 고빈도 프레임 샘플을 모아 4Hz로만 관찰 상태에 게시한다.
    func recordPerformance(deltaTime: Float, updateSeconds: Double, raycasts: Int) {
        diagnosticElapsed += deltaTime
        diagnosticUpdateSeconds += updateSeconds
        diagnosticRaycasts += raycasts
        diagnosticFrames += 1
        accumulatedFrames += 1
        guard diagnosticElapsed >= 0.25 else { return }

        let frames = max(diagnosticFrames, 1)
        totalFrames = accumulatedFrames
        frameRate = Float(frames) / diagnosticElapsed
        frameTimeMilliseconds = diagnosticElapsed / Float(frames) * 1_000
        physicsUpdateMilliseconds = Float(diagnosticUpdateSeconds / Double(frames) * 1_000)
        raycastsPerFrame = Float(diagnosticRaycasts) / Float(frames)
        diagnosticElapsed = 0
        diagnosticUpdateSeconds = 0
        diagnosticRaycasts = 0
        diagnosticFrames = 0
    }

    private func resetPerformanceDiagnostics() {
        totalFrames = 0
        frameRate = 0
        frameTimeMilliseconds = 0
        physicsUpdateMilliseconds = 0
        raycastsPerFrame = 0
        diagnosticElapsed = 0
        diagnosticUpdateSeconds = 0
        diagnosticRaycasts = 0
        diagnosticFrames = 0
        accumulatedFrames = 0
    }
}
