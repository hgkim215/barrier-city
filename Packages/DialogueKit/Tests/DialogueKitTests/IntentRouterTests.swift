import XCTest
@testable import DialogueKit

final class IntentRouterTests: XCTestCase {
    private let router = IntentRouter()

    func test_accessibilityRequests_areClassifiedLocally() {
        XCTAssertEqual(router.infer(from: "경사로가 없어서 못 들어가요").kind, .helpRequest)
        XCTAssertEqual(router.infer(from: "문 좀 잡아주시겠어요?").kind, .helpRequest)
    }

    func test_orderAndLeave_areClassifiedLocally() {
        XCTAssertEqual(router.infer(from: "아메리카노 한 잔 주세요").kind, .orderRequest)
        XCTAssertEqual(router.infer(from: "그냥 나갈게요").kind, .leave)
    }

    func test_highKioskComplaint_isTreatedAsOrderAccommodationRequest() {
        XCTAssertEqual(router.infer(from: "키오스크가 너무 높아서 손이 안 닿아요").kind, .orderRequest)
    }

    func test_contextualReachBarrier_withoutRepeatingKiosk_isRecognized() {
        let utterances = [
            "손이 안 닿아서 그러는데 여기서 해주시면 안 돼요?",
            "아니 저 손이 안 닿아서 그러는데요. 닫아주시면 안 되나요?",
            "선반에 손이 안 닿아요",
        ]

        for utterance in utterances {
            XCTAssertTrue(router.describesKioskAccessBarrier(in: utterance), utterance)
            XCTAssertEqual(router.infer(from: utterance).kind, .orderRequest, utterance)
        }
        XCTAssertFalse(router.describesKioskAccessBarrier(in: "여기서 주문해 주세요"))
    }

    func test_rainbowSmoothie_withBarrier_isConcreteOrderAndPreservesBarrierSignal() {
        let utterance = "키오스크 화면에 손이 안 닿아서 레인보우 스무디 주세요"

        XCTAssertEqual(router.infer(from: utterance).kind, .orderComplete)
        XCTAssertTrue(router.describesKioskAccessBarrier(in: utterance))
    }

    func test_onlyRainbowSmoothie_isMissionOrder() {
        XCTAssertEqual(router.infer(from: "레인보우스무디 하나 주세요").kind, .orderComplete)
        XCTAssertEqual(router.infer(from: "레인보우 마카롱 스무디 한 잔 주세요").kind, .orderComplete)
        XCTAssertEqual(router.infer(from: "아메리카노 주세요").kind, .orderRequest)
        XCTAssertEqual(router.infer(from: "딸기 스무디 주세요").kind, .orderRequest)
        XCTAssertEqual(router.infer(from: "레인보우 스무디 두 잔 주세요").kind, .orderRequest)
        XCTAssertEqual(router.infer(from: "레인보우 스무디 12잔 주세요").kind, .orderRequest)
        XCTAssertEqual(router.infer(from: "레인보우 스무디 말고 라떼 주세요").kind, .orderRequest)
    }

    func test_realtimeMissionProgress_requiresTranscriptEvidenceAndPersonalityAttempts() {
        var cautious = RainbowSmoothieMissionProgress(personality: .cautious)

        XCTAssertEqual(
            cautious.observe(userTranscript: "레인보우 스무디 주세요"),
            .continueConversation
        )
        XCTAssertFalse(cautious.canComplete)
        XCTAssertEqual(
            cautious.observe(userTranscript: "키오스크가 높아서 손이 안 닿아요"),
            .continueConversation
        )
        XCTAssertFalse(cautious.canComplete)
        XCTAssertEqual(
            cautious.observe(userTranscript: "진짜 안 닿아요. 직접 받아주세요"),
            .askItem
        )
        XCTAssertTrue(cautious.acceptsCounterOrder)
        XCTAssertEqual(
            cautious.observe(userTranscript: "레인보우 스무디 주세요"),
            .askQuantity
        )
        XCTAssertFalse(cautious.canComplete)
        XCTAssertEqual(cautious.observe(userTranscript: "한 잔이요"), .completeOrder)
        XCTAssertTrue(cautious.canComplete)

        cautious.reset()
        cautious.observe(userTranscript: "키오스크가 높아서 손이 안 닿으니 레인보우 스무디 두 잔 주세요")
        cautious.observe(userTranscript: "그래도 직접 받아주세요")
        XCTAssertFalse(cautious.canComplete)

        var hurried = RainbowSmoothieMissionProgress(personality: .hurried)
        XCTAssertEqual(
            hurried.observe(userTranscript: "키오스크가 높아서 손이 안 닿으니 레인보우 마카롱 스무디 한 잔 주세요"),
            .completeOrder
        )
        XCTAssertTrue(hurried.canComplete)

        var correctedQuantity = RainbowSmoothieMissionProgress(personality: .hurried)
        XCTAssertEqual(
            correctedQuantity.observe(userTranscript: "키오스크가 높아서 손이 안 닿으니 레인보우 스무디 두 잔 주세요"),
            .askQuantity
        )
        XCTAssertFalse(correctedQuantity.canComplete)
        XCTAssertEqual(correctedQuantity.observe(userTranscript: "한 잔이요"), .completeOrder)
    }

    func test_realtimeMissionCoordinator_keepsOrdinaryConversationToolFree() {
        var coordinator = RealtimeMissionCoordinator()

        XCTAssertEqual(
            coordinator.observe(userTranscript: "오늘 원두가 다 떨어졌어요?"),
            .ordinaryConversation
        )
        XCTAssertEqual(
            coordinator.observe(userTranscript: "아메리카노 한 잔 주세요"),
            .ordinaryConversation
        )
        XCTAssertTrue(coordinator.snapshot.isPristine)
    }

    func test_realtimeMissionCoordinator_requiresExactMacaronItem() {
        var coordinator = RealtimeMissionCoordinator()

        XCTAssertEqual(
            coordinator.observe(userTranscript: "레인보우 스무디 한 잔 주세요"),
            .ordinaryConversation
        )
        XCTAssertEqual(
            coordinator.observe(userTranscript: "레인보우 마카롱 스무디 맛있어요?"),
            .ordinaryConversation
        )
        XCTAssertEqual(
            coordinator.observe(userTranscript: "레인보우 마카롱 스무디 한 잔 주세요"),
            .missionOrderCandidate
        )
    }

    func test_realtimeMissionCoordinator_distinguishesCorrectionFromCancellation() {
        var correction = RealtimeMissionCoordinator()
        XCTAssertEqual(
            correction.observe(userTranscript: "아니, 레인보우 마카롱 스무디 한 잔 주세요"),
            .missionOrderCandidate
        )

        var cancellation = RealtimeMissionCoordinator()
        cancellation.observe(userTranscript: "레인보우 마카롱 스무디 주세요")
        XCTAssertEqual(
            cancellation.observe(userTranscript: "레인보우 마카롱 스무디 말고 라떼 주세요"),
            .ordinaryConversation
        )
        XCTAssertTrue(cancellation.snapshot.isPristine)
    }

    func test_realtimeMissionCoordinator_itemThenQuantity_exposesToolOnlyWhenComplete() {
        var coordinator = RealtimeMissionCoordinator()

        XCTAssertEqual(
            coordinator.observe(userTranscript: "레인보우 마카롱 스무디 주세요"),
            .partialMissionOrder
        )
        coordinator.clearEncounterTransientState()
        XCTAssertTrue(coordinator.snapshot.hasMissionItem)
        XCTAssertEqual(
            coordinator.observe(userTranscript: "한 잔이요"),
            .missionOrderCandidate
        )
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_placeMissionOrder_validatesJSONAndPublishesExactlyOnce() {
        var coordinator = RealtimeMissionCoordinator()
        coordinator.observe(userTranscript: "레인보우 마카롱 스무디 한 잔 주세요")
        let arguments = #"{"item":"rainbow_macaron_smoothie","quantity":1}"#
        _ = coordinator.register(
            name: "place_mission_order",
            callID: "call-1",
            arguments: arguments
        )

        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        XCTAssertTrue(coordinator.takeFunctionCall()?.output.contains(#""success":true"#) == true)
        XCTAssertEqual(coordinator.takeCompletedEvent(), .orderPlaced)
        XCTAssertNil(coordinator.takeCompletedEvent())

        _ = coordinator.register(
            name: "place_mission_order",
            callID: "call-2",
            arguments: arguments
        )
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_placeMissionOrder_rejectsInvalidJSONWithoutMissionEvent() {
        var coordinator = RealtimeMissionCoordinator()
        coordinator.observe(userTranscript: "레인보우 마카롱 스무디 한 잔 주세요")
        _ = coordinator.register(
            name: "place_mission_order",
            callID: "call-invalid",
            arguments: #"{"item":"rainbow_macaron_smoothie","quantity":2}"#
        )

        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        XCTAssertNil(coordinator.takeCompletedEvent())
        XCTAssertTrue(coordinator.takeFunctionCall()?.output.contains(#""success":false"#) == true)
    }

    func test_encounterCleanup_preservesMissionSlotsAndPendingCompletion() {
        var coordinator = RealtimeMissionCoordinator()
        coordinator.observe(userTranscript: "레인보우 마카롱 스무디 주세요")
        coordinator.clearEncounterTransientState()
        XCTAssertTrue(coordinator.snapshot.hasMissionItem)
        XCTAssertEqual(coordinator.observe(userTranscript: "한 잔이요"), .missionOrderCandidate)

        _ = coordinator.register(
            name: "place_mission_order",
            callID: "call-preserved",
            arguments: #"{"item":"rainbow_macaron_smoothie","quantity":1}"#
        )
        coordinator.clearEncounterTransientState()
        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        XCTAssertEqual(coordinator.takeCompletedEvent(), .orderPlaced)
    }

    func test_immersiveReset_clearsMissionProgress() {
        var coordinator = RealtimeMissionCoordinator()
        coordinator.observe(userTranscript: "레인보우 마카롱 스무디 한 잔 주세요")
        _ = coordinator.register(
            name: "place_mission_order",
            callID: "call-reset",
            arguments: #"{"item":"rainbow_macaron_smoothie","quantity":1}"#
        )

        coordinator.resetImmersiveProgress()

        XCTAssertTrue(coordinator.snapshot.isPristine)
        XCTAssertNil(coordinator.takeFunctionCall())
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_orderToolEvaluation_comparesCandidateAndFunctionCall() {
        var coordinator = RealtimeMissionCoordinator()
        coordinator.observe(userTranscript: "레인보우 마카롱 스무디 한 잔 주세요")
        _ = coordinator.register(
            name: "place_mission_order",
            callID: "call-order",
            arguments: #"{"item":"rainbow_macaron_smoothie","quantity":1}"#
        )

        XCTAssertEqual(
            coordinator.finishOrderToolEvaluation(),
            .init(
                outcome: .agreement,
                localOrderReady: true,
                modelProposedOrder: true,
                argumentsValid: true
            )
        )
    }

    func test_onlyCompletedOrderEndsConversationAfterResponse() {
        XCTAssertFalse(RainbowSmoothieOrderDecision.continueConversation.endsConversationAfterResponse)
        XCTAssertFalse(RainbowSmoothieOrderDecision.askItem.endsConversationAfterResponse)
        XCTAssertFalse(RainbowSmoothieOrderDecision.askQuantity.endsConversationAfterResponse)
        XCTAssertTrue(RainbowSmoothieOrderDecision.completeOrder.endsConversationAfterResponse)
    }

    func test_oneCupSpeechTranscriptionVariants_completeTheKnownItem() {
        let variants = [
            "한 잔이요", "한 장이요", "한 컵이요", "하나요", "일 잔이요",
            "1잔이요", "1장이요", "1개요", "1컵이요",
        ]

        for transcript in variants {
            var progress = RainbowSmoothieMissionProgress(personality: .hurried)
            XCTAssertEqual(
                progress.observe(userTranscript: "키오스크가 높아 손이 안 닿아서 레인보우 스무디 주세요"),
                .askQuantity,
                transcript
            )
            XCTAssertEqual(
                progress.observe(userTranscript: transcript),
                .completeOrder,
                transcript
            )
        }
    }

    func test_shortBarrierInsistence_isRecognizedForStatefulFollowUp() {
        XCTAssertTrue(router.continuesAccessRequest(in: "진짜 안 닿아요"))
        XCTAssertTrue(router.continuesAccessRequest(in: "그래도 직접 받아주세요"))
        XCTAssertFalse(router.continuesAccessRequest(in: "오늘 날씨 좋네요"))
    }

    func test_genericOrderRequest_waitsForConcreteMenuItem() {
        XCTAssertEqual(router.infer(from: "주문하고 싶어요").kind, .orderRequest)
        XCTAssertEqual(router.infer(from: "메뉴가 뭐예요?").kind, .orderRequest)
    }

    func test_orderComplete_waitsForOrderStateMachine() {
        XCTAssertNil(router.route(DialogueIntent(kind: .orderComplete)))
    }

    func test_helpRequest_mapsTo_helpRequested() {
        XCTAssertEqual(router.route(DialogueIntent(kind: .helpRequest)), .helpRequested)
    }

    func test_leave_mapsTo_exited() {
        XCTAssertEqual(router.route(DialogueIntent(kind: .leave)), .exited)
    }

    func test_smalltalk_and_unknown_mapTo_nil() {
        XCTAssertNil(router.route(DialogueIntent(kind: .orderRequest)))
        XCTAssertNil(router.route(DialogueIntent(kind: .smalltalk)))
        XCTAssertNil(router.route(DialogueIntent(kind: .unknown)))
    }
}
