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

    // MARK: 기준 높이 갱신(최솟값 트래킹)

    func testUpdatedBaseline_nilCurrentReturnsHeadY() {
        XCTAssertEqual(KioskFlowLogic.updatedBaseline(current: nil, headY: 1.6), 1.6)
    }
    func testUpdatedBaseline_lowerHeadYLowersBaseline() {
        XCTAssertEqual(KioskFlowLogic.updatedBaseline(current: 1.6, headY: 1.0), 1.0)
    }
    func testUpdatedBaseline_higherHeadYKeepsBaseline() {
        XCTAssertEqual(KioskFlowLogic.updatedBaseline(current: 1.0, headY: 1.6), 1.0)
    }
    func testUpdatedBaseline_standingAtEntryThenSittingThenStandingTriggersGuard() {
        // 입장 시 서 있는 상태(1.6m)로 기준이 굳지 않아야 한다.
        var baseline: Float? = nil
        baseline = KioskFlowLogic.updatedBaseline(current: baseline, headY: 1.6)
        // 이후 앉음(1.0m) → 최솟값 트래킹으로 기준이 앉은 높이까지 내려감.
        baseline = KioskFlowLogic.updatedBaseline(current: baseline, headY: 1.0)
        // 다시 일어섬(1.6m) → 기준(1.0) 대비 rise 0.6m가 enter(0.25)를 초과해 가드가 발동해야 한다.
        let standing = KioskFlowLogic.standUpShown(currentlyShown: false, headY: 1.6,
                                                    baselineY: baseline!,
                                                    enter: KioskTuning.standUpEnter,
                                                    exit: KioskTuning.standUpExit)
        XCTAssertTrue(standing)
    }

    // MARK: 경계값(포함/제외 edge)

    func testCanReach_exactlyAtMarginEdgeReaches() {
        // 판정이 `>=`이므로 존 최소 높이 − 여유 '정확히 그 지점'은 닿음이어야 한다.
        let zone: Float = 1.4
        let margin: Float = 0.05
        let handY = zone - margin   // 내부와 같은 식으로 계산해 부동소수 오차를 없앤다
        XCTAssertTrue(KioskFlowLogic.canReach(hand: SIMD3(0, handY, -0.8),
                                              kioskXZ: SIMD2(0, -1),
                                              zoneMinY: zone, margin: margin, maxXZ: 1.2))
    }

    func testCanReach_exactlyAtMaxHorizontalDistanceReaches() {
        // 판정이 `<=`이므로 수평 최대 거리 '정확히 그 값'은 닿음이어야 한다.
        // 1.25는 이진 부동소수로 정확히 표현돼 sqrt(1.25²) == 1.25가 성립한다.
        let maxXZ: Float = 1.25
        XCTAssertTrue(KioskFlowLogic.canReach(hand: SIMD3(1.25, 1.5, 0),
                                              kioskXZ: SIMD2(0, 0),
                                              zoneMinY: 1.4, margin: 0.05, maxXZ: maxXZ))
    }

    func testStandUp_exactlyAtEnterThresholdStaysHidden() {
        // 판정이 `>`이므로 기준+enter '정확히 그 지점'은 아직 표시하지 않는다.
        let baseline: Float = 1.0
        let enter: Float = 0.25
        XCTAssertFalse(KioskFlowLogic.standUpShown(currentlyShown: false,
                                                   headY: baseline + enter,
                                                   baselineY: baseline,
                                                   enter: enter, exit: 0.15))
    }

    func testStandUp_exactlyAtExitThresholdHides() {
        // 판정이 `>`이므로 기준+exit '정확히 그 지점'은 해제되어야 한다.
        let baseline: Float = 1.0
        let exitValue: Float = 0.15
        XCTAssertFalse(KioskFlowLogic.standUpShown(currentlyShown: true,
                                                   headY: baseline + exitValue,
                                                   baselineY: baseline,
                                                   enter: 0.25, exit: exitValue))
    }

    // MARK: 근접 판정(트리거 2개 공존)
    //
    // 실내에는 키오스크(r 3.0)와 NPC(r 2.5) 트리거가 동시에 등록된다.
    // 아래 배치에서 z=2.9는 "NPC가 더 가깝지만 자기 반경 밖" 구간이다.

    private static let kioskT = ProximityTrigger(id: "kiosk.order", center: SIMD2(0, 0),
                                                 radius: 3.0, kind: .kioskScreen,
                                                 prompt: "주문하기")
    private static let npcT = ProximityTrigger(id: "npc.staff", center: SIMD2(0, 5.5),
                                               radius: 2.5, kind: .npcDialogue,
                                               prompt: "직원에게 주문하기")

    func testEvaluate_activeStaysShownWhenNearerTriggerIsOutOfRange() {
        // z=2.9: 키오스크 2.9m(반경 3.0 안), NPC 2.6m(반경 2.5 밖, 하지만 더 가깝다).
        let v = InteractionModel.evaluate(playerX: 0, playerZ: 2.9,
                                          triggers: [Self.kioskT, Self.npcT],
                                          activeID: "kiosk.order", dismissedID: nil)
        XCTAssertEqual(v.showID, "kiosk.order")
    }

    func testEvaluate_nearerInRangeTriggerTakesOver() {
        // z=3.2: NPC 2.3m(반경 안, 더 가깝다) → 키오스크가 아직 히스테리시스 안이어도 교체.
        let v = InteractionModel.evaluate(playerX: 0, playerZ: 3.2,
                                          triggers: [Self.kioskT, Self.npcT],
                                          activeID: "kiosk.order", dismissedID: nil)
        XCTAssertEqual(v.showID, "npc.staff")
    }

    func testEvaluate_activeClosesOnceOutsideItsOwnHysteresis() {
        // NPC를 멀리 두어 오직 키오스크 히스테리시스만 판정에 관여하게 한다.
        let farNPC = ProximityTrigger(id: "npc.staff", center: SIMD2(0, 20),
                                      radius: 2.5, kind: .npcDialogue, prompt: "직원에게 주문하기")
        // 3.5m > 3.0 + 0.4 → 닫힘.
        let out = InteractionModel.evaluate(playerX: 0, playerZ: 3.5,
                                            triggers: [Self.kioskT, farNPC],
                                            activeID: "kiosk.order", dismissedID: nil)
        XCTAssertNil(out.showID)
        // 3.3m ≤ 3.4 → 유지.
        let inside = InteractionModel.evaluate(playerX: 0, playerZ: 3.3,
                                               triggers: [Self.kioskT, farNPC],
                                               activeID: "kiosk.order", dismissedID: nil)
        XCTAssertEqual(inside.showID, "kiosk.order")
    }

    func testEvaluate_dismissedBehaviorUnchanged() {
        // 거절한 트리거는 범위 안에서 계속 숨김.
        let near = InteractionModel.evaluate(playerX: 0, playerZ: 1,
                                             triggers: [Self.kioskT],
                                             activeID: nil, dismissedID: "kiosk.order")
        XCTAssertNil(near.showID)
        XCTAssertFalse(near.clearDismissed)
        // 범위 밖으로 나가면 해제되어 재접근 시 다시 뜬다.
        let far = InteractionModel.evaluate(playerX: 0, playerZ: 20,
                                            triggers: [Self.kioskT],
                                            activeID: nil, dismissedID: "kiosk.order")
        XCTAssertNil(far.showID)
        XCTAssertTrue(far.clearDismissed)
    }

    // MARK: NPC 완료 이벤트 재발행 판정

    func testRefireNPCDone_firesOnActivationWhenQuestIsWaiting() {
        XCTAssertTrue(InteractionSetup.shouldRefireNPCDone(activationEdge: true,
                                                           completed: true,
                                                           pendingEvent: .npcHelpDone))
    }
    func testRefireNPCDone_notFiredWithoutActivationEdge() {
        XCTAssertFalse(InteractionSetup.shouldRefireNPCDone(activationEdge: false,
                                                            completed: true,
                                                            pendingEvent: .npcHelpDone))
    }
    func testRefireNPCDone_notFiredWhenOrderNotCompleted() {
        XCTAssertFalse(InteractionSetup.shouldRefireNPCDone(activationEdge: true,
                                                            completed: false,
                                                            pendingEvent: .npcHelpDone))
    }
    func testRefireNPCDone_notFiredWhenQuestWaitsOnAnotherEvent() {
        XCTAssertFalse(InteractionSetup.shouldRefireNPCDone(activationEdge: true,
                                                            completed: true,
                                                            pendingEvent: .kioskFailed))
        XCTAssertFalse(InteractionSetup.shouldRefireNPCDone(activationEdge: true,
                                                            completed: true,
                                                            pendingEvent: nil))
    }

    // MARK: 퀘스트 순서 — NPC 주문을 키오스크보다 먼저 한 경우

    @MainActor
    func testQuestOrdering_npcDoneBeforeKioskStillLeavesFinalStepReachable() {
        PressureAudio.isEnabled = false   // 오디오·네트워크 부수 효과 차단
        QuestModel.shared.reset()
        NPCOrderModel.shared.reset()
        defer {
            QuestModel.shared.reset()
            NPCOrderModel.shared.reset()
        }

        QuestModel.shared.advance(on: .enteredIndoor)
        XCTAssertEqual(QuestModel.shared.currentStep?.id, "quest.tryKiosk")

        // 키오스크보다 먼저 NPC에게 주문 → 2단계 대기 중이라 무시된다.
        QuestModel.shared.advance(on: .npcHelpDone)
        XCTAssertEqual(QuestModel.shared.currentStep?.id, "quest.tryKiosk")

        QuestModel.shared.advance(on: .kioskFailed)
        XCTAssertEqual(QuestModel.shared.currentStep?.completionEvent, .npcHelpDone)

        // 이 시점에 재발행 조건이 성립해야 최종 단계에 도달할 수 있다.
        XCTAssertTrue(InteractionSetup.shouldRefireNPCDone(
            activationEdge: true, completed: true,
            pendingEvent: QuestModel.shared.currentStep?.completionEvent))
        QuestModel.shared.advance(on: .npcHelpDone)
        XCTAssertNil(QuestModel.shared.currentStep)
    }
}
