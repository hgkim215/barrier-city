import RealityKit
import simd

/// 물리 기반 차동 구동(우리 엔진) + USDA 메시를 광선으로 읽는 충돌.
///
/// CharacterController(캡슐)를 쓰지 않는다. 대신:
///  - 바닥/경사로/낮은 턱/기울기: 바퀴·캐스터 접지점에 down-ray로 높이를 읽어 옛 엔진 그대로.
///  - 벽(수직): 진행 방향 forward-ray 3발(몸체 박스 폭). 법선이 수직이면 막힘(경사로는 안 막음).
/// 위치/자세는 모두 우리가 적분하고, worldRoot를 그 역(inverse)으로 배치(world-inverse 시야).
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
    private static let gravity: Float = 6.0          // 경사 미끄러짐 세기
    private static let fallGravityY: Float = 9.8     // 수직 낙하 중력
    private static let minImpactVel: Float = 0.8

    // 몸체 치수(충돌/지지점)
    private static let bodyFront: Float = 0.32   // 중심→앞 충돌 거리(작을수록 벽에 더 가까이 가서 막힘)
    private static let bodyRear: Float = 0.20
    private static let bodyHalfWidth: Float = 0.30   // 벽 광선 좌우 오프셋
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
    private static let surgeGain: Float = 0.25

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

        MainActor.assumeIsolated {
            guard let model = AppModel.current, let worldRoot = model.worldRoot else { return }
            model.tick += 1

            // 한 점 바닥 높이(down-ray, groundGroup만). 없으면 nil(허공).
            func groundY(_ x: Float, _ z: Float) -> Float? {
                let hits = scene.raycast(origin: [x, 4, z], direction: [0, -1, 0],
                                         length: 8, query: .nearest, mask: AppModel.groundGroup)
                return hits.first?.position.y
            }
            // 진행 방향에 수직 벽이 있는지(몸체 폭 3점 forward-ray). 경사로/완만턱은 법선이 위라 통과.
            func wallAhead(fromX: Float, fromZ: Float, dxn: Float, dzn: Float, dist: Float, baseY: Float) -> Bool {
                let px = dzn, pz = -dxn   // 진행 방향에 수직
                for off in [-Self.bodyHalfWidth, 0, Self.bodyHalfWidth] {
                    let ox = fromX + px * off, oz = fromZ + pz * off
                    let hits = scene.raycast(origin: [ox, baseY + Self.wallRayY, oz],
                                             direction: [dxn, 0, dzn], length: dist,
                                             query: .all, mask: AppModel.groundGroup)
                    // 완만한 경사면이 먼저 맞더라도 그 뒤의 수직 벽까지 검사한다.
                    if hits.contains(where: { abs($0.normal.y) < 0.5 }) { return true }
                }
                return false
            }

            // 전복(게임오버)
            if model.fallen {
                let tgtP = model.fallDirPitch * Self.fallAngle
                let tgtR = model.fallDirRoll  * Self.fallAngle
                model.pitchVel += (Self.fallK * (tgtP - model.pitch) - Self.fallC * model.pitchVel) * dt
                model.rollVel  += (Self.fallK * (tgtR - model.roll ) - Self.fallC * model.rollVel ) * dt
                model.pitch += model.pitchVel * dt
                model.roll  += model.rollVel  * dt
                let mag = (model.pitch * model.pitch + model.roll * model.roll).squareRoot()
                if mag > Self.fallAngle {
                    let s = Self.fallAngle / mag
                    model.pitch *= s; model.roll *= s
                    model.pitchVel = 0; model.rollVel = 0
                }
                model.vL = 0; model.vR = 0
                Self.applyWorld(worldRoot, model: model)
                return
            }

            // 1) 입력
            let imp = model.consumeImpulses()
            if imp.left != 0 || imp.right != 0 { model.impulseApplied += 1 }
            let braking = model.brakeRequested
            model.brakeRequested = false

            // 2) 밀기
            model.vL += imp.left * Self.pushGain
            model.vR += imp.right * Self.pushGain

            // 3) 감속
            model.vL = Self.applyFriction(model.vL, dt: dt)
            model.vR = Self.applyFriction(model.vR, dt: dt)
            if braking { model.vL *= 0.2; model.vR *= 0.2 }

            // 잡은 바퀴 클러치
            if model.leftGrabbed  { model.vL = Self.clutch(model.vL, toward: model.handSpeedLeft, dt: dt) }
            if model.rightGrabbed { model.vR = Self.clutch(model.vR, toward: model.handSpeedRight, dt: dt) }

            model.vL = max(-Self.maxSpeed, min(Self.maxSpeed, model.vL))
            model.vR = max(-Self.maxSpeed, min(Self.maxSpeed, model.vR))

            // 4) 차동 구동
            let forward = (model.vL + model.vR) * 0.5
            let omega = (model.vR - model.vL) / Self.wheelBase
            let clampedOmega = max(-Self.maxOmega, min(Self.maxOmega, omega))
            model.heading += clampedOmega * dt
            let dirX = -sin(model.heading)
            let dirZ = -cos(model.heading)

            // 5) 경사 미끄러짐: 바라보는 방향 경사만큼 속도 가감(놓은 바퀴만).
            let hHere = groundY(model.posX, model.posZ) ?? model.chairY
            let hAhead = groundY(model.posX + dirX * 0.06, model.posZ + dirZ * 0.06) ?? hHere
            let slope = (hAhead - hHere) / 0.06
            let dv = -Self.gravity * slope * dt
            if !model.leftGrabbed  { model.vL += dv }
            if !model.rightGrabbed { model.vR += dv }

            // 6) 이동 후보 + 충돌
            let newX = model.posX + dirX * forward * dt
            let newZ = model.posZ + dirZ * forward * dt
            let movingFwd = forward >= 0
            let leadDirX = movingFwd ? dirX : -dirX
            let leadDirZ = movingFwd ? dirZ : -dirZ
            let leadExtent = movingFwd ? Self.bodyFront : Self.bodyRear

            // 몸체 앞/뒤 끝뿐 아니라 이번 프레임에 이동할 구간까지 훑어 저프레임에서도
            // 얇은 벽을 한 번에 통과(tunneling)하지 않게 한다.
            let sweepDistance = leadExtent + abs(forward) * dt + Self.collisionSkin
            if wallAhead(fromX: model.posX, fromZ: model.posZ, dxn: leadDirX, dzn: leadDirZ,
                         dist: sweepDistance, baseY: model.chairY) {
                // 수직 벽: 하드 스톱
                if !model.blocked {
                    model.surgeVel = forward * Self.surgeGain
                    ImpactAudio.shared.playThunk(intensity: min(1, abs(forward) / Self.maxSpeed))
                }
                model.vL *= 0.1; model.vR *= 0.1
                model.blocked = true
            } else {
                // 낮은 턱/계단 단차: 진행 끝의 높이 상승으로 판정.
                let lx = newX + leadDirX * leadExtent, lz = newZ + leadDirZ * leadExtent
                let h0 = groundY(lx, lz) ?? model.chairY
                let h1 = groundY(lx + leadDirX * Self.stepProbe, lz + leadDirZ * Self.stepProbe) ?? h0
                let rise = h1 - h0
                if rise > Self.climbLimit {
                    // 못 넘는 단차(계단) → 막힘
                    if !model.blocked {
                        model.surgeVel = forward * Self.surgeGain
                        ImpactAudio.shared.playThunk(intensity: min(1, abs(forward) / Self.maxSpeed))
                    }
                    model.vL *= 0.1; model.vR *= 0.1
                    model.blocked = true
                } else if rise > Self.stepMin {
                    // 넘을 수 있는 낮은 턱 → 저항 후 통과
                    let resist = min(1, rise / Self.climbLimit)
                    let f = max(0, 1 - resist * Self.climbDrag * dt)
                    model.vL *= f; model.vR *= f
                    model.posX = newX; model.posZ = newZ
                    model.blocked = false
                } else {
                    model.posX = newX; model.posZ = newZ
                    model.blocked = false
                }
            }

            // 7) 수직 위치: 여러 점 평균 높이(격자 노이즈 완화) + 부드럽게 따라가기(저역통과).
            let g0 = groundY(model.posX, model.posZ)
            let gAh = groundY(model.posX + dirX * 0.18, model.posZ + dirZ * 0.18)
            let gBk = groundY(model.posX - dirX * 0.18, model.posZ - dirZ * 0.18)
            let solids = [g0, gAh, gBk].compactMap { $0 }
            let centerGround: Float? = solids.isEmpty ? nil : solids.reduce(0, +) / Float(solids.count)

            if let g = centerGround, model.chairY <= g + 0.02 {
                // 지면 위/근처: 즉시 스냅 대신 부드럽게 따라가 미세 요철을 흡수.
                let dy = g - model.chairY
                if dy > Self.stepBlock {
                    model.bumpVel = Self.bumpKick * 0.6
                    ImpactAudio.shared.playBump(intensity: min(1, dy / 0.15))
                }
                model.chairY += dy * min(1, 18 * dt)
                model.fallVelY = 0
            } else {
                model.fallVelY -= Self.fallGravityY * dt
                model.chairY += model.fallVelY * dt
                let g = centerGround ?? -1000
                if model.chairY <= g {
                    let impactVel = -model.fallVelY
                    model.chairY = g
                    model.fallVelY = 0
                    if impactVel > Self.minImpactVel {
                        let impact = min(1, impactVel / 3.0)
                        model.bumpVel = Self.bumpKick * (0.4 + 0.6 * impact)
                        ImpactAudio.shared.playBump(intensity: max(0.25, impact))
                    }
                }
            }
            model.groundY = centerGround ?? model.chairY

            // 8) 바퀴 시각 회전
            model.wheelAngleLeft  += (model.vL * dt) / AppModel.wheelRadius
            model.wheelAngleRight += (model.vR * dt) / AppModel.wheelRadius

            // 9) 기울기: 표면 '법선 평균'으로 경사(점 높이차 노이즈 없이 매끈) + 모서리 지지손실(전복).
            let rightX = cos(model.heading), rightZ = -sin(model.heading)
            let px = model.posX, pz = model.posZ
            func contact(_ ro: Float, _ fo: Float) -> (Float, Float) {
                (px + rightX * ro + dirX * fo, pz + rightZ * ro + dirZ * fo)
            }
            // 한 점의 (바닥높이, 법선). 없으면 nil(허공).
            func groundHit(_ x: Float, _ z: Float) -> (Float, SIMD3<Float>)? {
                let hits = scene.raycast(origin: [x, 4, z], direction: [0, -1, 0],
                                         length: 8, query: .nearest, mask: AppModel.groundGroup)
                if let h = hits.first { return (h.position.y, h.normal) }
                return nil
            }
            let rl = contact(-Self.contactHalfTrack, Self.rearForward)
            let rr = contact( Self.contactHalfTrack, Self.rearForward)
            let fl = contact(-Self.contactHalfTrack, Self.frontForward)
            let fr = contact( Self.contactHalfTrack, Self.frontForward)
            let hRL = groundHit(rl.0, rl.1), hRR = groundHit(rr.0, rr.1)
            let hFL = groundHit(fl.0, fl.1), hFR = groundHit(fr.0, fr.1)
            let hC  = groundHit(px, pz)

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
            if model.blocked { targetPitch = 0; targetRoll = 0 }
            if abs(targetPitch) < Self.tiltDeadzone { targetPitch = 0 }
            if abs(targetRoll)  < Self.tiltDeadzone { targetRoll = 0 }
            targetPitch = max(-Self.maxTip, min(Self.maxTip, targetPitch))
            targetRoll  = max(-Self.maxTip, min(Self.maxTip, targetRoll))

            let lean = (model.pitch * model.pitch + model.roll * model.roll).squareRoot()
            if lean <= Self.criticalLean {
                model.pitchVel += (Self.tiltK * (targetPitch - model.pitch) - Self.tiltC * model.pitchVel) * dt
                model.rollVel  += (Self.tiltK * (targetRoll  - model.roll ) - Self.tiltC * model.rollVel ) * dt
            } else {
                let accel = Self.tipGravity * (lean - Self.criticalLean)
                let inv = 1 / lean
                model.pitchVel += (accel * model.pitch * inv - Self.tipDamp * model.pitchVel) * dt
                model.rollVel  += (accel * model.roll  * inv - Self.tipDamp * model.rollVel ) * dt
            }
            model.pitch += model.pitchVel * dt
            model.roll  += model.rollVel  * dt

            let leanNow = (model.pitch * model.pitch + model.roll * model.roll).squareRoot()
            if leanNow > Self.fallenThreshold {
                model.fallen = true
                let n = max(leanNow, 1e-4)
                model.fallDirPitch = model.pitch / n
                model.fallDirRoll = model.roll / n
                ImpactAudio.shared.playThunk(intensity: 1)
            }

            // 덜컹/흔들림 스프링
            model.bumpVel += (-Self.bumpSpring * model.bumpOffset - Self.bumpDamp * model.bumpVel) * dt
            model.bumpOffset += model.bumpVel * dt
            model.surgeVel += (-Self.surgeSpring * model.surgeOffset - Self.surgeDamp * model.surgeVel) * dt
            model.surgeOffset += model.surgeVel * dt

            model.speed = forward
            model.headingDegrees = model.heading * 180 / .pi

            let dGoal = simd_distance(SIMD2(model.posX, model.posZ), Terrain.goal)
            if dGoal < Terrain.goalRadius { model.reachedGoal = true }

            Self.applyWorld(worldRoot, model: model)
        }
    }

    /// 보이는 카페(worldRoot)를 가상 위치/자세의 역(inverse)으로 배치 → world-inverse 시야.
    @MainActor
    private static func applyWorld(_ worldRoot: Entity, model: AppModel) {
        let invYaw = simd_quatf(angle: -model.heading, axis: [0, 1, 0])
        let invPitch = simd_quatf(angle: -model.pitch, axis: [1, 0, 0])
        let invRoll = simd_quatf(angle: model.roll, axis: [0, 0, 1])
        let rot = invRoll * invPitch * invYaw
        let dirX = -sin(model.heading), dirZ = -cos(model.heading)
        var pe = SIMD3<Float>(model.posX, model.chairY + model.bumpOffset - AppModel.viewHeightOffset, model.posZ)
        pe.x -= dirX * model.surgeOffset
        pe.z -= dirZ * model.surgeOffset
        worldRoot.transform = Transform(scale: .one, rotation: rot, translation: rot.act(-pe))
    }

    private static func clutch(_ v: Float, toward hand: Float, dt: Float) -> Float {
        let startup = min(1, abs(v) / startThreshold)
        let factor = startEase + (1 - startEase) * startup
        let acc = (hand - v) * gripK
        return v + acc * factor * dt
    }

    private static func applyFriction(_ v: Float, dt: Float) -> Float {
        var s = v
        s -= s * rollingResistance * dt
        let dec = constantFriction * dt
        if s > dec { s -= dec } else if s < -dec { s += dec } else { s = 0 }
        return s
    }
}
