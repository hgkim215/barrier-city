import RealityKit
import simd

/// 손님/바리스타 NPC가 목적지를 향해 걸을 때 가구·벽 콜리전(groundGroup)을 뚫고
/// 지나가지 않도록, 이동 방향으로 짧은 레이를 쏴서 실제로 갈 수 있는 거리로 이동
/// 폭을 줄인다. 휠체어의 WheelchairMovementSystem.wallDistance()와 같은 원리이지만
/// 몸이 좁아 샘플을 3개로 줄인다. NPC끼리는(npcGroup) 서로 밀어내며 걷지 않도록
/// groundGroup만 검사한다.
enum NPCObstacleAvoidance {
    /// Indoor.usda의 /Root/collision/Cube 프록시 대부분은 중심 y≈0.19m,
    /// 높이≈0.4m라 상단이 약 0.39m다. 0.5m 레이는 그 위를 지나가므로 몸통 하단
    /// 높이에서 검사한다.
    private static let rayHeight: Float = 0.2
    private static let skin: Float = 0.03
    /// 휠체어의 전후 외곽(0.42m)을 원형으로 보수적으로 근사한다.
    private static let wheelchairRadius: Float = 0.42

    /// - Parameter avoidPlayer: 평소 배회 중에는 NPC가 사용자 몸으로 걸어 들어가지
    ///   않도록 반경 안쪽 이동을 막아야 하지만(기본값 true), 대기줄처럼 의도적으로
    ///   사용자 바로 뒤까지 다가가야 하는 이동에는 이 검사를 꺼야 한다. 그렇지
    ///   않으면 대기줄 목표 지점이 이 반경(halfWidth+wheelchairRadius+skin,
    ///   guest 기준 약 0.65m)보다 가까울 때 도착하지 못하고 그 경계에서 멈춘다.
    /// - Parameter neighborPositions: 배회 중인 다른 NPC들의 현재 위치. crowdSteeredDirection의
    ///   개인 공간 반발력은 방향만 부드럽게 트는 조향이라, 두 NPC가 정면으로 빠르게
    ///   마주치면 실제로 몸이 겹쳐 지나가는 순간이 보일 수 있었다. 여기서 각 이웃에
    ///   대해 사용자와 동일한 원-원 스윕 계산으로 스텝 자체를 하드하게 잘라 겹침을
    ///   원천 차단한다.
    static func allowedStep(scene: RealityKit.Scene,
                            from position: SIMD3<Float>,
                            direction: SIMD3<Float>,
                            desiredStep: Float,
                            halfWidth: Float,
                            playerPosition: SIMD2<Float>,
                            avoidPlayer: Bool = true,
                            neighborPositions: [SIMD2<Float>] = []) -> Float {
        guard desiredStep > 0 else { return 0 }
        let perpendicular = SIMD3<Float>(direction.z, 0, -direction.x)
        var nearest: Float = desiredStep
        for fraction: Float in [-1, 0, 1] {
            let offset = perpendicular * (halfWidth * fraction)
            let origin = SIMD3(position.x + offset.x,
                               position.y + rayHeight,
                               position.z + offset.z)
            let hits = scene.raycast(origin: origin, direction: direction,
                                     length: desiredStep + skin, query: .all,
                                     mask: AppModel.groundGroup)
            for hit in hits where abs(hit.normal.y) < 0.5 {
                let hitDistance = simd_distance(hit.position, origin)
                nearest = min(nearest, max(0, hitDistance - skin))
            }
        }
        let position2D = SIMD2(position.x, position.z)
        let direction2D = SIMD2(direction.x, direction.z)
        if avoidPlayer {
            nearest = min(nearest, allowedStepPastCircle(
                from: position2D,
                direction: direction2D,
                desiredStep: desiredStep,
                clearance: halfWidth + wheelchairRadius + skin,
                targetPosition: playerPosition))
        }
        if !neighborPositions.isEmpty {
            // 두 NPC 모두 halfWidth 반경의 원으로 근사하므로, 두 반경의 합이 서로
            // 겹치지 않을 최소 간격이다.
            let neighborClearance = halfWidth * 2 + skin
            for neighbor in neighborPositions {
                nearest = min(nearest, allowedStepPastCircle(
                    from: position2D,
                    direction: direction2D,
                    desiredStep: desiredStep,
                    clearance: neighborClearance,
                    targetPosition: neighbor))
            }
        }
        return nearest
    }

    /// NPC도 직접 transform으로 움직이므로, 대상(사용자 휠체어 또는 다른 NPC)이
    /// 정지해 있을 때에는 레이 sweep만으로 접촉을 막을 수 없다. 논리 맵 좌표에서
    /// 이동하는 원과 정지한 원의 swept 교차를 계산해 그 방향으로 걸어 들어오는
    /// 것도 차단한다.
    private static func allowedStepPastCircle(
        from position: SIMD2<Float>,
        direction: SIMD2<Float>,
        desiredStep: Float,
        clearance: Float,
        targetPosition: SIMD2<Float>
    ) -> Float {
        let relative = position - targetPosition
        let distanceSquared = simd_length_squared(relative)
        let clearanceSquared = clearance * clearance

        // 이미 겹친 상태라면 더 멀어지는 이동만 허용해 탈출할 수 있게 한다.
        if distanceSquared < clearanceSquared {
            return simd_dot(relative, direction) > 0 ? desiredStep : 0
        }

        let toward = -simd_dot(relative, direction)
        guard toward > 0 else { return desiredStep }
        let perpendicularSquared = distanceSquared - toward * toward
        guard perpendicularSquared < clearanceSquared else { return desiredStep }

        let entryDistance = toward - sqrt(max(0, clearanceSquared - perpendicularSquared))
        return min(desiredStep, max(0, entryDistance))
    }
}
