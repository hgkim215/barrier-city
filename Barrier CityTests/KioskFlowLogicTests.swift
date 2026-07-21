//
//  KioskFlowLogicTests.swift
//  Barrier CityTests
//
//  키오스크 상태 전이·리치·일어서기 판정(순수 함수) 단위 테스트.
//

import XCTest
import simd
@testable import Barrier_City

final class KioskFlowLogicTests: XCTestCase {

    // MARK: 유휴 시간 초과

    func testIdleTimeout_browsingGoesToResetting() {
        XCTAssertEqual(KioskFlowLogic.afterIdleTimeout(.browsing), .resetting)
    }
    func testIdleTimeout_paymentGoesToResetting() {
        XCTAssertEqual(KioskFlowLogic.afterIdleTimeout(.payment), .resetting)
    }
    func testIdleTimeout_failedStaysFailed() {
        XCTAssertEqual(KioskFlowLogic.afterIdleTimeout(.failed), .failed)
    }
    func testIdleTimeout_resettingStaysResetting() {
        XCTAssertEqual(KioskFlowLogic.afterIdleTimeout(.resetting), .resetting)
    }

    // MARK: 리셋 연출 종료

    func testResetHold_resettingGoesToBrowsing() {
        XCTAssertEqual(KioskFlowLogic.afterResetHold(.resetting), .browsing)
    }
    func testResetHold_otherPhasesUnchanged() {
        XCTAssertEqual(KioskFlowLogic.afterResetHold(.payment), .payment)
        XCTAssertEqual(KioskFlowLogic.afterResetHold(.failed), .failed)
    }

    // MARK: 결제 시도

    func testPaymentAttempt_incrementsBelowThreshold() {
        let r = KioskFlowLogic.afterPaymentAttempt(phase: .payment, attempts: 0, maxAttempts: 3)
        XCTAssertEqual(r.phase, .payment)
        XCTAssertEqual(r.attempts, 1)
    }
    func testPaymentAttempt_failsAtThreshold() {
        let r = KioskFlowLogic.afterPaymentAttempt(phase: .payment, attempts: 2, maxAttempts: 3)
        XCTAssertEqual(r.phase, .failed)
        XCTAssertEqual(r.attempts, 3)
    }
    func testPaymentAttempt_ignoredOutsidePayment() {
        let r = KioskFlowLogic.afterPaymentAttempt(phase: .browsing, attempts: 0, maxAttempts: 3)
        XCTAssertEqual(r.phase, .browsing)
        XCTAssertEqual(r.attempts, 0)
    }

    // MARK: 리치 판정

    func testCanReach_nilHandNeverReaches() {
        XCTAssertFalse(KioskFlowLogic.canReach(hand: nil, kioskXZ: SIMD2(0, -1),
                                               zoneMinY: 1.4, margin: 0.05, maxXZ: 1.2))
    }
    func testCanReach_highHandNearKioskReaches() {
        // 키오스크 바로 앞에서 손을 1.5m까지 올림 → 닿음
        XCTAssertTrue(KioskFlowLogic.canReach(hand: SIMD3(0, 1.5, -0.8), kioskXZ: SIMD2(0, -1),
                                              zoneMinY: 1.4, margin: 0.05, maxXZ: 1.2))
    }
    func testCanReach_lowHandDoesNotReach() {
        // 앉은 손 높이(1.1m) → 안 닿음
        XCTAssertFalse(KioskFlowLogic.canReach(hand: SIMD3(0, 1.1, -0.8), kioskXZ: SIMD2(0, -1),
                                               zoneMinY: 1.4, margin: 0.05, maxXZ: 1.2))
    }
    func testCanReach_farHandDoesNotReach() {
        // 높이는 충분해도 키오스크에서 3m 떨어짐 → 안 닿음
        XCTAssertFalse(KioskFlowLogic.canReach(hand: SIMD3(3, 1.6, -1), kioskXZ: SIMD2(0, -1),
                                               zoneMinY: 1.4, margin: 0.05, maxXZ: 1.2))
    }
    func testCanReach_marginAllowsSlightlyBelowZone() {
        // 존 최소 높이보다 여유(margin)만큼 아래까지는 닿음 처리
        XCTAssertTrue(KioskFlowLogic.canReach(hand: SIMD3(0, 1.36, -0.8), kioskXZ: SIMD2(0, -1),
                                              zoneMinY: 1.4, margin: 0.05, maxXZ: 1.2))
    }

    // MARK: 일어서기 판정(히스테리시스)

    func testStandUp_entersAboveEnterThreshold() {
        XCTAssertTrue(KioskFlowLogic.standUpShown(currentlyShown: false, headY: 1.30,
                                                  baselineY: 1.0, enter: 0.25, exit: 0.15))
    }
    func testStandUp_staysHiddenBelowEnterThreshold() {
        XCTAssertFalse(KioskFlowLogic.standUpShown(currentlyShown: false, headY: 1.20,
                                                   baselineY: 1.0, enter: 0.25, exit: 0.15))
    }
    func testStandUp_staysShownUntilExitThreshold() {
        // 표시 중에는 exit 아래로 내려와야 해제(깜빡임 방지)
        XCTAssertTrue(KioskFlowLogic.standUpShown(currentlyShown: true, headY: 1.20,
                                                  baselineY: 1.0, enter: 0.25, exit: 0.15))
        XCTAssertFalse(KioskFlowLogic.standUpShown(currentlyShown: true, headY: 1.10,
                                                   baselineY: 1.0, enter: 0.25, exit: 0.15))
    }
}
