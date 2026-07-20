import RealityKit
import simd

/// 휠체어의 물리 상태와 튜닝 파라미터.
/// `worldRoot`(바닥/마커)에 부착한다.
///
/// 물리 모델: 각 바퀴는 지면 위를 구르는 '선속도(vL, vR)'를 가진다.
/// 손으로 미는 동작은 이 속도에 '충격량(impulse)'을 더한다(=한 번의 stroke).
/// 손을 떼면 운동량이 보존되어 굴러가다가, 구름저항 + 마찰로 감속한다.
struct WheelchairComponent: Component {

    // MARK: 현재 상태 (세계 좌표 기준)
    var posX: Float = 0
    var posZ: Float = 0
    /// 진행 방향(라디안, Y축 회전). 0 = -Z(정면).
    var heading: Float = 0

    /// 좌/우 바퀴의 현재 지면 선속도(m/s). 운동량을 담는 핵심 상태.
    var vL: Float = 0
    var vR: Float = 0

    // MARK: 튜닝 파라미터
    /// 충격량 1.0 → 바퀴 속도 증가(m/s). 한 번 미는 세기.
    var pushGain: Float = 1.0
    /// 구름저항(속도 비례 감속, 1/s). 빠를수록 더 많이 줄어듦.
    var rollingResistance: Float = 0.9
    /// 정지 마찰(속도와 무관한 일정 감속, m/s²). 결국 멈추게 만든다.
    var constantFriction: Float = 0.25
    /// 좌우 바퀴 간 거리(m). 회전 곡률에 영향.
    var wheelBase: Float = 0.6
    /// 최대 속도(m/s) 안전 한계.
    var maxSpeed: Float = 2.6
}
