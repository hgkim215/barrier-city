//
//  KioskFlowModelTests.swift
//  Barrier CityTests
//
//  KioskFlowModel 통합 동작(타이머·전이·근접 실패) 테스트.
//  싱글턴이지만 reset()으로 매 테스트 초기화한다. tick은 dt 주입식이라 결정적.
//

import XCTest
@testable import Barrier_City

@MainActor
final class KioskFlowModelTests: XCTestCase {

    let item = KioskMenuItem(id: "americano", name: "아메리카노", price: 4000)

    override func setUp() async throws {
        PressureAudio.isEnabled = false   // 오디오·네트워크 부수 효과 차단
        KioskFlowModel.shared.reset()
        KioskFlowModel.shared.isActive = true
    }

    func testIdleTimeout_resetsCartAndCountsReset() {
        let m = KioskFlowModel.shared
        m.addToCart(item)
        // 유휴 한계 + 1초 경과
        m.tick(dt: KioskTuning.idleLimit + 1, transitioning: false)
        XCTAssertEqual(m.phase, .resetting)
        XCTAssertEqual(m.resetCount, 1)
        XCTAssertTrue(m.cart.isEmpty)
        // 리셋 연출 종료 → 처음 화면 + 타이머 복구
        m.tick(dt: KioskTuning.resetHoldSeconds + 0.1, transitioning: false)
        XCTAssertEqual(m.phase, .browsing)
        XCTAssertEqual(m.idleRemaining, KioskTuning.idleLimit, accuracy: 0.01)
    }

    func testTickPaused_whenInactiveOrStandUpOrTransitioning() {
        let m = KioskFlowModel.shared
        m.isActive = false
        m.tick(dt: 999, transitioning: false)
        XCTAssertEqual(m.phase, .browsing)

        m.isActive = true
        m.standUpShown = true
        m.tick(dt: 999, transitioning: false)
        XCTAssertEqual(m.phase, .browsing)

        m.standUpShown = false
        m.tick(dt: 999, transitioning: true)
        XCTAssertEqual(m.phase, .browsing)
    }

    func testInputResetsIdleTimer() {
        let m = KioskFlowModel.shared
        m.tick(dt: KioskTuning.idleLimit - 1, transitioning: false)
        m.addToCart(item)   // 입력 → 타이머 리셋
        m.tick(dt: KioskTuning.idleLimit - 1, transitioning: false)
        XCTAssertEqual(m.phase, .browsing)   // 아직 리셋 안 됨
    }

    func testCategoryTapped_unreachableCountsNearMiss() {
        let m = KioskFlowModel.shared
        m.reachableUpper = false
        for _ in 0..<KioskTuning.nearMissHintCount { m.categoryTapped(1) }
        XCTAssertEqual(m.categoryIndex, 0)                 // 카테고리 안 바뀜
        XCTAssertEqual(m.upperNearMissCount, KioskTuning.nearMissHintCount)
        XCTAssertTrue(m.showsReachHint)
    }

    func testCategoryTapped_reachableSwitchesCategory() {
        let m = KioskFlowModel.shared
        m.reachableUpper = true   // 실기에서 정말 손이 닿은 경우(정직 판정)
        m.categoryTapped(2)
        XCTAssertEqual(m.categoryIndex, 2)
        XCTAssertEqual(m.upperNearMissCount, 0)
    }

    func testPaymentFlow_failsAtThresholdAndStaysFailed() {
        let m = KioskFlowModel.shared
        m.addToCart(item)
        m.proceedToPayment()
        XCTAssertEqual(m.phase, .payment)
        for _ in 0..<KioskTuning.paymentMaxAttempts { m.paymentConfirmTapped() }
        XCTAssertEqual(m.phase, .failed)
        // failed 이후는 타이머·입력에 반응하지 않는다(재접근 시 직원 안내 고정)
        m.tick(dt: 999, transitioning: false)
        m.paymentConfirmTapped()
        XCTAssertEqual(m.phase, .failed)
    }

    func testProceedToPayment_requiresCart() {
        let m = KioskFlowModel.shared
        m.proceedToPayment()
        XCTAssertEqual(m.phase, .browsing)   // 빈 장바구니로는 결제 화면 진입 불가
    }

    func testResumeAtTrigger_resetsOnlyIdleTimer() {
        // 트리거 이탈 후 재진입: 유휴 타이머만 리셋, 진행 상태(장바구니 등)는 유지(스펙 5장)
        let m = KioskFlowModel.shared
        m.addToCart(item)
        m.tick(dt: KioskTuning.idleLimit - 1, transitioning: false)
        m.resumeAtTrigger()
        XCTAssertEqual(m.idleRemaining, KioskTuning.idleLimit, accuracy: 0.01)
        XCTAssertEqual(m.cart.count, 1)
        XCTAssertEqual(m.phase, .browsing)
    }
}
