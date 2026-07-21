//
//  KioskTuning.swift
//  Barrier City
//
//  키오스크 체험 튜닝 상수 단일 진실원(InteractionTuning 패턴).
//  [실측 조정] 표기 상수는 실기 테스트에서 값을 확정한다.
//

import simd

enum KioskTuning {
    // MARK: 화면 존 경계(y, m) — 서 있는 성인 기준 키오스크
    //
    // 주의: 아래 두 값은 서로 다른 좌표계에 있다.
    //  - screenCenterY: 맵(worldRoot) 로컬 프레임. 패널을 맵에 배치할 때 쓴다.
    //  - upperZoneMinY: 씬 루트(실공간) 프레임. ARKit 손 높이와 직접 비교한다.
    // 지금 둘이 맞아떨어지는 것은 AppModel.viewHeightOffset == 0이고 평지 실내라
    // 두 프레임의 y가 같기 때문이다. viewHeightOffset을 0이 아닌 값으로 바꾸거나
    // 경사가 있는 곳에 키오스크를 두면 두 값을 함께 다시 맞춰야 한다.
    /// 키오스크 화면 패널 중심 높이(맵 프레임). [실측 조정]
    static let screenCenterY: Float = 1.25
    /// 이 높이 위는 '상단 존'(카테고리 탭·결제 버튼). 앉은 손은 못 닿는다.
    /// 실공간 프레임 기준 — 손 월드 좌표와 직접 비교된다. [실측 조정]
    static let upperZoneMinY: Float = 1.4
    /// 리치 판정 여유(m). 존 경계보다 이만큼 아래까지는 닿은 것으로 인정.
    static let reachMargin: Float = 0.05
    /// 리치 판정 대상이 되는 손-키오스크 수평 최대 거리(m).
    static let reachMaxXZ: Float = 1.2

    // MARK: 유휴 타이머
    /// 입력이 없을 때 처음 화면으로 리셋되기까지의 시간(초). 짧아야 장벽 ②가 잘 발동한다.
    static let idleLimit: Float = 20
    /// "처음 화면으로 돌아갑니다" 리셋 연출 유지 시간(초).
    static let resetHoldSeconds: Float = 3

    // MARK: 실패 임계
    /// 상단 존 근접 실패(near-miss)가 이 횟수 이상이면 "손이 닿지 않습니다" 안내 표시.
    static let nearMissHintCount = 3
    /// 결제 시도 실패가 이 횟수에 도달하면 최종 실패(장벽 ③).
    static let paymentMaxAttempts = 3

    // MARK: 일어서기 가드
    /// 기준 대비 머리가 이만큼 오르면 오버레이 표시(m).
    static let standUpEnter: Float = 0.25
    /// 표시 중 이 값 아래로 내려와야 해제(히스테리시스, m).
    static let standUpExit: Float = 0.15

    // MARK: NPC
    /// NPC 대화 트리거 진입 반경(m).
    static let npcTriggerRadius: Float = 2.5
    /// 카운터(Bar) 프림을 못 찾을 때 NPC 폴백 좌표(맵 좌표 x, z). [실측 조정]
    static let npcFallbackCenter = SIMD2<Float>(4, -4)
    /// NPC 모델 스케일·yaw. Skull.usdz 실물 확인 후 조정. [실측 조정]
    static let npcScale: Float = 1.0
    static let npcYaw: Float = .pi
}
