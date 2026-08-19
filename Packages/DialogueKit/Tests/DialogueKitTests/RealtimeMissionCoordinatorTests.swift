import XCTest
@testable import DialogueKit

final class RealtimeMissionCoordinatorTests: XCTestCase {
    func test_smallTalkRemainsToolFree_andFirstOrderRedirectsToKiosk() {
        var coordinator = RealtimeMissionCoordinator()

        XCTAssertEqual(
            coordinator.observe(userTranscript: "오늘 원두가 다 떨어졌어요?"),
            .ordinaryConversation
        )
        XCTAssertEqual(
            coordinator.observe(userTranscript: "아메리카노 한 잔 주세요"),
            .initialKioskRefusal
        )
        XCTAssertTrue(coordinator.snapshot.hasRedirectedFirstOrderToKiosk)
        XCTAssertFalse(coordinator.snapshot.hasMissionItem)
    }

    func test_requiresExactMacaronItem() {
        var coordinator = RealtimeMissionCoordinator()

        XCTAssertEqual(
            coordinator.observe(userTranscript: "레인보우 스무디 한 잔 주세요"),
            .initialKioskRefusal
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

    func test_distinguishesCorrectionFromCancellation() {
        var correction = RealtimeMissionCoordinator()
        XCTAssertEqual(
            correction.observe(userTranscript: "주문할게요"),
            .initialKioskRefusal
        )
        XCTAssertEqual(
            correction.observe(userTranscript: "아니, 레인보우 마카롱 스무디 한 잔 주세요"),
            .missionOrderCandidate
        )

        var cancellation = RealtimeMissionCoordinator()
        cancellation.observe(userTranscript: "레인보우 마카롱 스무디 주세요")
        cancellation.observe(userTranscript: "레인보우 마카롱 스무디 주세요")
        XCTAssertEqual(
            cancellation.observe(userTranscript: "레인보우 마카롱 스무디 말고 라떼 주세요"),
            .unavailableMenuRefusal
        )
        XCTAssertFalse(cancellation.snapshot.hasMissionItem)
        XCTAssertNil(cancellation.snapshot.requestedQuantity)
    }

    func test_itemThenQuantity_exposesToolOnlyWhenComplete() {
        var coordinator = RealtimeMissionCoordinator()

        XCTAssertEqual(
            coordinator.observe(userTranscript: "레인보우 마카롱 스무디 주세요"),
            .initialKioskRefusal
        )
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
        var coordinator = readyCoordinator()
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
        var coordinator = readyCoordinator()
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
        var coordinator = readyCoordinator()
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
        var coordinator = readyCoordinator()
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

    func test_rejectsDifferentMenuWithoutAlternativeRoute() {
        var coordinator = RealtimeMissionCoordinator()

        XCTAssertEqual(
            coordinator.observe(userTranscript: "아메리카노 한 잔 주세요"),
            .initialKioskRefusal
        )
        XCTAssertEqual(
            coordinator.observe(userTranscript: "그럼 라떼 한 잔 주세요"),
            .unavailableMenuRefusal
        )
        let guide = RealtimeMissionRoutingDecision.unavailableMenuRefusal.promptGuide
        XCTAssertTrue(guide.contains("insufficient beans"))
        XCTAssertTrue(guide.contains("Do not offer, recommend, or ask about another"))
        XCTAssertTrue(guide.contains("Do not suggest the kiosk"))
    }

    func test_oneCupSpeechTranscriptionVariants_completeTheKnownItem() {
        let variants = [
            "한 잔이요", "한 장이요", "한 컵이요", "하나요", "일 잔이요",
            "1잔이요", "1장이요", "1개요", "1컵이요",
        ]

        for transcript in variants {
            var coordinator = RealtimeMissionCoordinator()
            XCTAssertEqual(
                coordinator.observe(userTranscript: "주문할게요"),
                .initialKioskRefusal,
                transcript
            )
            XCTAssertEqual(
                coordinator.observe(userTranscript: "레인보우 마카롱 스무디 주세요"),
                .partialMissionOrder,
                transcript
            )
            XCTAssertEqual(
                coordinator.observe(userTranscript: transcript),
                .missionOrderCandidate,
                transcript
            )
        }
    }

    func test_routingPrompts_enforceKioskFirst_andNoAlternativeForOtherMenus() {
        let firstOrder = RealtimeMissionRoutingDecision.initialKioskRefusal.promptGuide
        XCTAssertTrue(firstOrder.contains("first explicit attempt"))
        XCTAssertTrue(firstOrder.contains("must be placed at the kiosk"))
        XCTAssertTrue(firstOrder.contains("Do not ask what they want"))

        let unavailable = RealtimeMissionRoutingDecision.unavailableMenuRefusal.promptGuide
        XCTAssertTrue(unavailable.contains("unavailable ingredients"))
        XCTAssertTrue(unavailable.contains("Do not offer, recommend, or ask about another"))
        XCTAssertTrue(unavailable.contains("another ordering method"))
    }

    private func readyCoordinator() -> RealtimeMissionCoordinator {
        var coordinator = RealtimeMissionCoordinator()
        coordinator.observe(userTranscript: "레인보우 마카롱 스무디 한 잔 주세요")
        coordinator.observe(userTranscript: "레인보우 마카롱 스무디 한 잔 주세요")
        return coordinator
    }
}
