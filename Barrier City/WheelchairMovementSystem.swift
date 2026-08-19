import Foundation
import RealityKit
import simd

/// 물리 기반 차동 구동(우리 엔진) + USDA 메시를 광선으로 읽는 충돌.
///
/// CharacterController(캡슐)를 쓰지 않는다. 대신:
///  - 바닥/경사로/낮은 턱/기울기: 바퀴·캐스터 접지점에 down-ray로 높이를 읽어 옛 엔진 그대로.
///  - 벽(수직): 진행 방향 forward-ray 3발(몸체 박스 폭). 법선이 수직이면 막힘(경사로는 안 막음).
/// 위치/자세는 모두 우리가 적분하고, worldRoot를 그 역(inverse)으로 배치(world-inverse 시야).
@MainActor
struct WheelchairMovementSystem: System {

    // 구동
    private static let pushGain: Float = 0.37  // 바퀴에 들어가는 힘(작을수록 살짝 밀어선 덜 나감)
    // 마찰(관성)은 원래대로 — 평지 관성 보존 + 내리막 미끄러짐 유지.
    private static let rollingResistance: Float = 0.2
    private static let constantFriction: Float = 0.1
    private static let gripK: Float = 3.0
    private static let startThreshold: Float = 0.5
    private static let startEase: Float = 0.25
    private static let wheelBase: Float = 1.1
    private static let maxSpeed: Float = 5.0
    private static let maxOmega: Float = 1.8
    /// 테스트용 가상 스틱 목표 속도를 따라가는 응답 속도(초당 비율).
    private static let fistDriveResponse: Float = 8.0
    /// 마지막 손 샘플이 끊긴 뒤 안전 정지까지 허용할 최대 시간.
    private static let fistDriveStaleTimeout: TimeInterval = 0.25
    private static let gravity: Float = 6.0          // 경사 미끄러짐 세기
    private static let fallGravityY: Float = 9.8     // 수직 낙하 중력
    private static let minImpactVel: Float = 0.8

    // 몸체 치수(충돌/지지점)
    // WhellChair.usdz를 ImmersiveView의 scale/offset/뒷바퀴 보정까지 적용하면
    // 사용자 원점 기준 외곽은 전후 약 0.42m, 좌우 약 0.36m다. 이전 값은 이보다
    // 6~10cm 작아서 바퀴가 벽 안으로 들어간 뒤에야 충돌한 것처럼 보였다.
    private static let bodyFront: Float = 0.42
    private static let bodyRear: Float = 0.42
    private static let bodyHalfWidth: Float = 0.37
    private static let wallRayY: Float = 0.45         // 벽 광선 높이(바닥 위)
    private static let collisionSkin: Float = 0.02   // 프레임 경계·부동소수 오차용 여유
    private static let climbLimit: Float = AppModel.wheelRadius * 0.15   // ≈0.05
    private static let climbDrag: Float = 6.0
    private static let stepProbe: Float = 0.10
    private static let stepMin: Float = 0.02
    private static let stepBlock: Float = 0.03

    // 덜컹/흔들림
    private static let bumpSpring: Float = 110
    private static let bumpDamp: Float = 7
    private static let bumpKick: Float = -1.6
    private static let surgeSpring: Float = 80
    private static let surgeDamp: Float = 8
    private static let surgeGain: Float = 0.36
    /// 실제 조작에서 흔한 약 1.3m/s를 최대 충격 음량 기준으로 사용한다.
    /// 물리 안전 상한(maxSpeed=5)을 기준으로 하면 보통 속도의 충돌음이 지나치게 작다.
    private static let impactReferenceSpeed: Float = 1.3

    // 기울기
    private static let tiltK: Float = 35
    private static let tiltC: Float = 12
    private static let maxTip: Float = 0.7
    private static let pitchDiveMax: Float = 0.2
    private static let rollDiveMax: Float = 0.6
    private static let voidTol: Float = 0.05
    private static let contactHalfTrack: Float = 0.36
    private static let rearForward: Float = 0.12
    private static let frontForward: Float = 0.30
    private static let tiltGain: Float = 1.6
    private static let tiltDeadzone: Float = 0.04
    // 전복
    private static let criticalLean: Float = 0.35
    private static let tipGravity: Float = 10
    private static let tipDamp: Float = 1.0
    private static let fallenThreshold: Float = 1.2
    private static let fallAngle: Float = 1.5
    private static let fallK: Float = 18
    private static let fallC: Float = 4

    init(scene: Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        guard dt > 0 else { return }
        let scene = context.scene

        do {
            guard let model = AppModel.current, let worldRoot = model.worldRoot else { return }
            let motion = model.motion
            if GuideFlowModel.shared.isInteractionLocked {
                model.discardGuideLockedInput()
                Self.applyWorld(worldRoot, model: model)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let updateStartedAt = now
            var raycastCount = 0
            defer {
                motion.recordPerformance(
                    deltaTime: dt,
                    updateSeconds: ProcessInfo.processInfo.systemUptime - updateStartedAt,
                    raycasts: raycastCount)
            }
            if model.testFistDriveEnabled,
               model.fistDriveActive,
               now - model.fistDriveLastUpdate > Self.fistDriveStaleTimeout {
                model.stopFistDrive(
                    requestRecenter: true,
                    status: "손 추적이 끊겼습니다 · 손을 펴고 다시 쥐세요")
            }

            // 한 점의 (바닥높이, 법선). 없으면 nil(허공).
            func groundHit(_ x: Float, _ z: Float) -> (height: Float, normal: SIMD3<Float>)? {
                raycastCount += 1
                let hits = scene.raycast(origin: [x, 4, z], direction: [0, -1, 0],
                                         length: 8, query: .nearest, mask: AppModel.groundGroup)
                guard let hit = hits.first else { return nil }
                return (hit.position.y, hit.normal)
            }
            // 한 점 바닥 높이(down-ray, groundGroup만). 없으면 nil(허공).
            func groundY(_ x: Float, _ z: Float) -> Float? {
                groundHit(x, z)?.height
            }
            // 진행 방향의 수직 벽까지 가장 가까운 거리. 휠체어 폭을 5점으로 훑어
            // 좁은 기둥/테이블 다리가 3개 레이 사이로 빠지는 것을 막는다.
            // 경사로/완만턱은 법선이 위를 향하므로 여기서 막지 않고 아래 단차 로직에 맡긴다.
            func wallDistance(fromX: Float,
                              fromZ: Float,
                              dxn: Float,
                              dzn: Float,
                              dist: Float,
                              baseY: Float) -> Float? {
                let px = dzn, pz = -dxn   // 진행 방향에 수직
                var nearest: Float?
                for fraction: Float in [-1, -0.5, 0, 0.5, 1] {
                    let off = Self.bodyHalfWidth * fraction
                    let ox = fromX + px * off, oz = fromZ + pz * off
                    raycastCount += 1
                    let hits = scene.raycast(origin: [ox, baseY + Self.wallRayY, oz],
                                             direction: [dxn, 0, dzn], length: dist,
                                             query: .all, mask: AppModel.groundGroup)
                    // 완만한 경사면이 먼저 맞더라도 그 뒤의 수직 벽까지 검사한다.
                    for hit in hits where abs(hit.normal.y) < 0.5 {
                        let hitDistance = simd_distance(hit.position, SIMD3<Float>(ox, baseY + Self.wallRayY, oz))
                        nearest = min(nearest ?? hitDistance, hitDistance)
                    }
                }
                return nearest
            }

            // 벽/넘을 수 없는 단차에 닿았을 때 실제 이동 속도를 끊고, 시야 반동과
            // 충돌음을 한 번만 준다. 반동 속도는 비현실적으로 큰 테스트 입력에서도 제한한다.
            @MainActor
            func stopAtObstacle(impactSpeed: Float) {
                if !motion.isBlocked, abs(impactSpeed) > 0.01 {
                    let cappedImpact = max(-Self.impactReferenceSpeed,
                                           min(Self.impactReferenceSpeed, impactSpeed))
                    motion.surgeVelocity = cappedImpact * Self.surgeGain
                    let intensity = min(1, abs(impactSpeed) / Self.impactReferenceSpeed)
                    ImpactAudio.shared.playThunk(intensity: max(0.2, intensity))
                }
                motion.leftVelocity = 0
                motion.rightVelocity = 0
                motion.isBlocked = true
            }

            // 전복(게임오버)
            if motion.hasFallen {
                if model.fistDriveActive {
                    model.stopFistDrive(
                        requestRecenter: true,
                        status: "전복 상태 · 다시 시작한 뒤 주먹을 다시 쥐세요")
                }
                let tgtP = motion.fallDirectionPitch * Self.fallAngle
                let tgtR = motion.fallDirectionRoll  * Self.fallAngle
                motion.pitchVelocity += (Self.fallK * (tgtP - motion.pitch) - Self.fallC * motion.pitchVelocity) * dt
                motion.rollVelocity  += (Self.fallK * (tgtR - motion.roll ) - Self.fallC * motion.rollVelocity ) * dt
                motion.pitch += motion.pitchVelocity * dt
                motion.roll  += motion.rollVelocity  * dt
                let mag = (motion.pitch * motion.pitch + motion.roll * motion.roll).squareRoot()
                if mag > Self.fallAngle {
                    let s = Self.fallAngle / mag
                    motion.pitch *= s; motion.roll *= s
                    motion.pitchVelocity = 0; motion.rollVelocity = 0
                }
                motion.leftVelocity = 0; motion.rightVelocity = 0
                Self.applyWorld(worldRoot, model: model)
                return
            }

            // 1) 입력
            let imp = model.consumeImpulses()
            if imp.left != 0 || imp.right != 0 { model.impulseApplied += 1 }
            let braking = model.brakeRequested
            model.brakeRequested = false
            let hardStop = model.consumeFistDriveHardStop()

            // 2) 밀기
            if !model.testFistDriveEnabled {
                motion.leftVelocity += imp.left * Self.pushGain
                motion.rightVelocity += imp.right * Self.pushGain
            }

            // 3) 감속
            motion.leftVelocity = Self.applyFriction(motion.leftVelocity, dt: dt)
            motion.rightVelocity = Self.applyFriction(motion.rightVelocity, dt: dt)
            if braking { motion.leftVelocity *= 0.2; motion.rightVelocity *= 0.2 }
            if hardStop { motion.leftVelocity = 0; motion.rightVelocity = 0 }

            if model.testFistDriveEnabled {
                // 테스트 모드는 전용 목표 속도를 빠르게 추종한다. 주먹을 펴거나 추적이
                // 끊긴 inactive 상태에서는 경사/관성까지 포함해 안전하게 정지 유지한다.
                if model.fistDriveActive {
                    motion.leftVelocity = Self.followFistDrive(motion.leftVelocity, toward: model.fistDriveTargetLeft, dt: dt)
                    motion.rightVelocity = Self.followFistDrive(motion.rightVelocity, toward: model.fistDriveTargetRight, dt: dt)
                } else {
                    motion.leftVelocity = 0
                    motion.rightVelocity = 0
                }
            } else {
                // 실제 손으로 잡은 바퀴 클러치
                if model.leftGrabbed  { motion.leftVelocity = Self.clutch(motion.leftVelocity, toward: model.handSpeedLeft, dt: dt) }
                if model.rightGrabbed { motion.rightVelocity = Self.clutch(motion.rightVelocity, toward: model.handSpeedRight, dt: dt) }
            }

            motion.leftVelocity = max(-Self.maxSpeed, min(Self.maxSpeed, motion.leftVelocity))
            motion.rightVelocity = max(-Self.maxSpeed, min(Self.maxSpeed, motion.rightVelocity))

            // 4) 차동 구동
            let forward = (motion.leftVelocity + motion.rightVelocity) * 0.5
            let omega = (motion.rightVelocity - motion.leftVelocity) / Self.wheelBase
            let clampedOmega = max(-Self.maxOmega, min(Self.maxOmega, omega))
            motion.heading += clampedOmega * dt
            let dirX = -sin(motion.heading)
            let dirZ = -cos(motion.heading)

            // 5) 경사 미끄러짐: 바라보는 방향 경사만큼 속도 가감(놓은 바퀴만).
            let hHere = groundY(motion.positionX, motion.positionZ) ?? motion.chairHeight
            let hAhead = groundY(motion.positionX + dirX * 0.06, motion.positionZ + dirZ * 0.06) ?? hHere
            let slope = (hAhead - hHere) / 0.06
            let dv = -Self.gravity * slope * dt
            if !model.leftGrabbed, !model.testFistDriveEnabled  { motion.leftVelocity += dv }
            if !model.rightGrabbed, !model.testFistDriveEnabled { motion.rightVelocity += dv }

            // 6) 이동 후보 + 충돌
            let newX = motion.positionX + dirX * forward * dt
            let newZ = motion.positionZ + dirZ * forward * dt
            let movingFwd = forward >= 0
            let leadDirX = movingFwd ? dirX : -dirX
            let leadDirZ = movingFwd ? dirZ : -dirZ
            let leadExtent = movingFwd ? Self.bodyFront : Self.bodyRear
            // 단차는 `stepProbe` 끝에서 높이를 미리 읽으므로 시작점을 그만큼 안쪽에 둔다.
            // probe 끝이 실제 바퀴 외곽(leadExtent)에 오게 해 기존 턱/경사 진입 시점은 유지한다.
            let stepLeadExtent = max(0, leadExtent - Self.stepProbe)

            // 몸체 앞/뒤 끝뿐 아니라 이번 프레임에 이동할 구간까지 훑어 저프레임에서도
            // 얇은 벽을 한 번에 통과(tunneling)하지 않게 한다.
            let requestedTravel = abs(forward) * dt
            let sweepDistance = leadExtent + requestedTravel + Self.collisionSkin
            if requestedTravel > 0.0001,
               let hitDistance = wallDistance(fromX: motion.positionX,
                                               fromZ: motion.positionZ,
                                               dxn: leadDirX,
                                               dzn: leadDirZ,
                                               dist: sweepDistance,
                                               baseY: motion.chairHeight) {
                // 수직 벽: 이번 프레임의 이동을 통째로 버리지 않고, 외곽이 skin만
                // 남기고 닿는 지점까지만 이동한다. 저프레임에서도 관통하거나 멀찍이
                // 떠서 멈추지 않고 실제 접촉 위치가 일정해진다.
                let allowedTravel = max(0, hitDistance - leadExtent - Self.collisionSkin)
                let contactTravel = min(requestedTravel, allowedTravel)
                motion.positionX += leadDirX * contactTravel
                motion.positionZ += leadDirZ * contactTravel
                stopAtObstacle(impactSpeed: forward)
            } else if requestedTravel > 0.0001 {
                // 낮은 턱/계단 단차: 진행 끝의 높이 상승으로 판정.
                let lx = newX + leadDirX * stepLeadExtent
                let lz = newZ + leadDirZ * stepLeadExtent
                let h0 = groundY(lx, lz) ?? motion.chairHeight
                let h1 = groundY(lx + leadDirX * Self.stepProbe, lz + leadDirZ * Self.stepProbe) ?? h0
                let rise = h1 - h0
                if rise > Self.climbLimit {
                    // 못 넘는 단차(계단) → 막힘
                    stopAtObstacle(impactSpeed: forward)
                } else if rise > Self.stepMin {
                    // 넘을 수 있는 낮은 턱 → 저항 후 통과
                    let resist = min(1, rise / Self.climbLimit)
                    let f = max(0, 1 - resist * Self.climbDrag * dt)
                    motion.leftVelocity *= f; motion.rightVelocity *= f
                    motion.positionX = newX; motion.positionZ = newZ
                    motion.isBlocked = false
                } else {
                    motion.positionX = newX; motion.positionZ = newZ
                    motion.isBlocked = false
                }
            }

            // 7) 수직 위치: 여러 점 평균 높이(격자 노이즈 완화) + 부드럽게 따라가기(저역통과).
            let g0Hit = groundHit(motion.positionX, motion.positionZ)
            let g0 = g0Hit?.height
            let gAh = groundY(motion.positionX + dirX * 0.18, motion.positionZ + dirZ * 0.18)
            let gBk = groundY(motion.positionX - dirX * 0.18, motion.positionZ - dirZ * 0.18)
            let solids = [g0, gAh, gBk].compactMap { $0 }
            let centerGround: Float? = solids.isEmpty ? nil : solids.reduce(0, +) / Float(solids.count)

            if let g = centerGround, motion.chairHeight <= g + 0.02 {
                // 지면 위/근처: 즉시 스냅 대신 부드럽게 따라가 미세 요철을 흡수.
                let dy = g - motion.chairHeight
                if dy > Self.stepBlock {
                    // dy는 한 프레임에 다 흡수되지 않고 여러 프레임에 걸쳐 줄어들 수 있다.
                    // 래치로 이 구간에서 사운드/킥을 한 번만 내보내 매 프레임 재발화를 막는다.
                    if !motion.isBumpSettling {
                        motion.isBumpSettling = true
                        motion.bumpVelocity = Self.bumpKick * 0.6
                        ImpactAudio.shared.playBump(intensity: min(1, dy / 0.15))
                    }
                } else {
                    motion.isBumpSettling = false
                }
                motion.chairHeight += dy * min(1, 18 * dt)
                motion.fallVelocity = 0
            } else {
                motion.isBumpSettling = false
                motion.fallVelocity -= Self.fallGravityY * dt
                motion.chairHeight += motion.fallVelocity * dt
                let g = centerGround ?? -1000
                if motion.chairHeight <= g {
                    let impactVel = -motion.fallVelocity
                    motion.chairHeight = g
                    motion.fallVelocity = 0
                    if impactVel > Self.minImpactVel {
                        let impact = min(1, impactVel / 3.0)
                        motion.bumpVelocity = Self.bumpKick * (0.4 + 0.6 * impact)
                        ImpactAudio.shared.playBump(intensity: max(0.25, impact))
                    }
                }
            }
            motion.groundHeight = centerGround ?? motion.chairHeight

            // 8) 바퀴 시각 회전
            motion.leftWheelAngle  += (motion.leftVelocity * dt) / AppModel.wheelRadius
            motion.rightWheelAngle += (motion.rightVelocity * dt) / AppModel.wheelRadius

            // 9) 기울기: 표면 '법선 평균'으로 경사(점 높이차 노이즈 없이 매끈) + 모서리 지지손실(전복).
            let rightX = cos(motion.heading), rightZ = -sin(motion.heading)
            let px = motion.positionX, pz = motion.positionZ
            func contact(_ ro: Float, _ fo: Float) -> (Float, Float) {
                (px + rightX * ro + dirX * fo, pz + rightZ * ro + dirZ * fo)
            }
            let rl = contact(-Self.contactHalfTrack, Self.rearForward)
            let rr = contact( Self.contactHalfTrack, Self.rearForward)
            let fl = contact(-Self.contactHalfTrack, Self.frontForward)
            let fr = contact( Self.contactHalfTrack, Self.frontForward)
            let hRL = groundHit(rl.0, rl.1), hRR = groundHit(rr.0, rr.1)
            let hFL = groundHit(fl.0, fl.1), hFR = groundHit(fr.0, fr.1)
            let hC = g0Hit

            // 법선 평균 → 경사(가끔 격자 구멍을 때려도 평균이라 매끈).
            var nSum = SIMD3<Float>(0, 0, 0)
            for h in [hRL, hRR, hFL, hFR, hC] { if let h { nSum += h.1 } }
            let navg = simd_length(nSum) > 0.001 ? simd_normalize(nSum) : SIMD3<Float>(0, 1, 0)
            let ny = max(navg.y, 0.15)
            let slopePitch = atan(-(navg.x * dirX + navg.z * dirZ) / ny) * Self.tiltGain
            let slopeRoll  = atan(-(navg.x * rightX + navg.z * rightZ) / ny) * Self.tiltGain

            // 지지손실: 바닥이 '아예 없는'(nil) 모서리만 → 격자 구멍엔 안 속음.
            func u(_ h: (Float, SIMD3<Float>)?) -> Float { h == nil ? 1 : 0 }
            let frontU = (u(hFL) + u(hFR)) * 0.5
            let rearU  = (u(hRL) + u(hRR)) * 0.5
            let leftU  = (u(hFL) + u(hRL)) * 0.5
            let rightU = (u(hFR) + u(hRR)) * 0.5

            var targetPitch = slopePitch + (rearU - frontU) * Self.pitchDiveMax
            var targetRoll  = slopeRoll  + (rightU - leftU) * Self.rollDiveMax
            if motion.isBlocked { targetPitch = 0; targetRoll = 0 }
            if abs(targetPitch) < Self.tiltDeadzone { targetPitch = 0 }
            if abs(targetRoll)  < Self.tiltDeadzone { targetRoll = 0 }
            targetPitch = max(-Self.maxTip, min(Self.maxTip, targetPitch))
            targetRoll  = max(-Self.maxTip, min(Self.maxTip, targetRoll))

            let lean = (motion.pitch * motion.pitch + motion.roll * motion.roll).squareRoot()
            if lean <= Self.criticalLean {
                motion.pitchVelocity += (Self.tiltK * (targetPitch - motion.pitch) - Self.tiltC * motion.pitchVelocity) * dt
                motion.rollVelocity  += (Self.tiltK * (targetRoll  - motion.roll ) - Self.tiltC * motion.rollVelocity ) * dt
            } else {
                let accel = Self.tipGravity * (lean - Self.criticalLean)
                let inv = 1 / lean
                motion.pitchVelocity += (accel * motion.pitch * inv - Self.tipDamp * motion.pitchVelocity) * dt
                motion.rollVelocity  += (accel * motion.roll  * inv - Self.tipDamp * motion.rollVelocity ) * dt
            }
            motion.pitch += motion.pitchVelocity * dt
            motion.roll  += motion.rollVelocity  * dt

            let leanNow = (motion.pitch * motion.pitch + motion.roll * motion.roll).squareRoot()
            if leanNow > Self.fallenThreshold {
                motion.hasFallen = true
                let n = max(leanNow, 1e-4)
                motion.fallDirectionPitch = motion.pitch / n
                motion.fallDirectionRoll = motion.roll / n
                ImpactAudio.shared.playThunk(intensity: 1)
            }

            // 덜컹/흔들림 스프링
            motion.bumpVelocity += (-Self.bumpSpring * motion.bumpOffset - Self.bumpDamp * motion.bumpVelocity) * dt
            motion.bumpOffset += motion.bumpVelocity * dt
            motion.surgeVelocity += (-Self.surgeSpring * motion.surgeOffset - Self.surgeDamp * motion.surgeVelocity) * dt
            motion.surgeOffset += motion.surgeVelocity * dt

            motion.speed = forward
            motion.headingDegrees = motion.heading * 180 / .pi

            let dGoal = simd_distance(SIMD2(motion.positionX, motion.positionZ), Terrain.goal)
            if dGoal < Terrain.goalRadius { motion.reachedGoal = true }

            Self.applyWorld(worldRoot, model: model)
        }
    }

    /// 보이는 카페(worldRoot)를 가상 위치/자세의 역(inverse)으로 배치 → world-inverse 시야.
    @MainActor
    private static func applyWorld(_ worldRoot: Entity, model: AppModel) {
        let motion = model.motion
        let invYaw = simd_quatf(angle: -motion.heading, axis: [0, 1, 0])
        let invPitch = simd_quatf(angle: -motion.pitch, axis: [1, 0, 0])
        let invRoll = simd_quatf(angle: motion.roll, axis: [0, 0, 1])
        let rot = invRoll * invPitch * invYaw
        let dirX = -sin(motion.heading), dirZ = -cos(motion.heading)
        var pe = SIMD3<Float>(motion.positionX, motion.chairHeight + motion.bumpOffset - AppModel.viewHeightOffset, motion.positionZ)
        pe.x -= dirX * motion.surgeOffset
        pe.z -= dirZ * motion.surgeOffset
        worldRoot.transform = Transform(scale: .one, rotation: rot, translation: rot.act(-pe))
    }

    private static func clutch(_ v: Float, toward hand: Float, dt: Float) -> Float {
        let startup = min(1, abs(v) / startThreshold)
        let factor = startEase + (1 - startEase) * startup
        let acc = (hand - v) * gripK
        return v + acc * factor * dt
    }

    private static func followFistDrive(_ velocity: Float, toward target: Float, dt: Float) -> Float {
        velocity + (target - velocity) * min(1, fistDriveResponse * dt)
    }

    private static func applyFriction(_ v: Float, dt: Float) -> Float {
        var s = v
        s -= s * rollingResistance * dt
        let dec = constantFriction * dt
        if s > dec { s -= dec } else if s < -dec { s += dec } else { s = 0 }
        return s
    }
}
