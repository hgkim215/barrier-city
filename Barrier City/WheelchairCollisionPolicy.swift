/// 휠체어 전방 스윕에 잡힌 장애물 종류. 정적 환경과 움직이는 NPC를 구분해야
/// NPC 경계가 프레임마다 들어왔다 나갈 때 벽 충돌음과 시야 반동이 반복되지 않는다.
enum WheelchairObstacleKind: Equatable {
    case environment
    case npc
}

struct WheelchairObstacleHit: Equatable {
    let distance: Float
    let kind: WheelchairObstacleKind
}

/// 충돌 자체(이동 정지)와 사용자 피드백(쿵 소리/시야 반동)을 분리하는 순수 정책.
/// NPC 접촉은 안전하게 정지시키되 동적 경계의 미세한 출입로 덜덜거리지 않게
/// 피드백을 주지 않는다. 정적 환경도 아주 느린 접촉은 조용히 멈춘다.
enum WheelchairCollisionPolicy {
    static let minimumImpactFeedbackSpeed: Float = 0.3

    static func shouldPlayImpactFeedback(
        obstacleKind: WheelchairObstacleKind,
        impactSpeed: Float,
        wasAlreadyBlocked: Bool
    ) -> Bool {
        obstacleKind == .environment
            && !wasAlreadyBlocked
            && abs(impactSpeed) >= minimumImpactFeedbackSpeed
    }
}
