//
//  KioskFlowLogic.swift
//  Barrier City
//
//  키오스크 상태 전이·리치·일어서기 판정(순수 함수).
//  QuestProgression 패턴 — KioskFlowModel이 호출하고 단위 테스트가 직접 검증한다.
//

import simd

/// 키오스크 화면 단계.
enum KioskPhase: Equatable {
    case browsing    // 메뉴 탐색·장바구니
    case resetting   // 시간 초과 리셋 연출 중
    case payment     // 결제 화면
    case failed      // 최종 실패(직원 안내)
}

enum KioskFlowLogic {

    /// 유휴 시간 초과: 조작 중(browsing·payment)에만 리셋 연출로 전이.
    static func afterIdleTimeout(_ phase: KioskPhase) -> KioskPhase {
        switch phase {
        case .browsing, .payment: return .resetting
        case .resetting, .failed: return phase
        }
    }

    /// 리셋 연출 종료 → 처음 화면.
    static func afterResetHold(_ phase: KioskPhase) -> KioskPhase {
        phase == .resetting ? .browsing : phase
    }

    /// 결제 시도 실패 누적. 임계 도달 시 최종 실패.
    static func afterPaymentAttempt(phase: KioskPhase, attempts: Int,
                                    maxAttempts: Int) -> (phase: KioskPhase, attempts: Int) {
        guard phase == .payment else { return (phase, attempts) }
        let n = attempts + 1
        return (n >= maxAttempts ? .failed : .payment, n)
    }

    /// 리치 판정: 손이 키오스크 수평 근방(maxXZ)에 있고 손 높이가
    /// 존 최소 높이 − 여유 이상이면 닿음. hand가 nil(시뮬레이터·추적 불가)이면 항상 실패.
    static func canReach(hand: SIMD3<Float>?, kioskXZ: SIMD2<Float>,
                         zoneMinY: Float, margin: Float, maxXZ: Float) -> Bool {
        guard let hand else { return false }
        let horiz = simd_distance(SIMD2(hand.x, hand.z), kioskXZ)
        return horiz <= maxXZ && hand.y >= zoneMinY - margin
    }

    /// 일어서기 오버레이 표시 여부(히스테리시스).
    /// 미표시 → 기준+enter 초과 시 표시. 표시 중 → 기준+exit 아래로 내려와야 해제.
    static func standUpShown(currentlyShown: Bool, headY: Float, baselineY: Float,
                             enter: Float, exit: Float) -> Bool {
        let rise = headY - baselineY
        return currentlyShown ? rise > exit : rise > enter
    }

    /// 기준 높이 갱신: 관측된 머리 높이의 최솟값을 기준으로 삼는다.
    /// 최초 샘플만 쓰면 사용자가 '서 있는 상태로 입장'했을 때 기준이 서 있는 높이로
    /// 굳어 가드가 영영 발동하지 않는다(= 배리어 무력화). 최솟값을 쓰면 앉는 순간
    /// 기준이 다시 내려간다.
    /// 트레이드오프: 사용자가 한 번 크게 고개를 숙이면 기준이 그만큼 낮아져
    /// 바로 앉은 자세가 '일어섬'으로 잡힐 수 있다. 무음으로 배리어가 사라지는 것보다
    /// 눈에 보이는 오탐이 낫다고 판단해 최솟값을 택한다.
    static func updatedBaseline(current: Float?, headY: Float) -> Float {
        guard let current else { return headY }
        return min(current, headY)
    }
}
