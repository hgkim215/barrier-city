import XCTest
@testable import DialogueKit

final class RealtimeMissionCoordinatorTests: XCTestCase {
    private let validArguments = #"{"item":"rainbow_macaron_smoothie","quantity":1}"#

    func test_firstCall_isAlwaysRedirectedToKiosk_regardlessOfValidity() {
        var coordinator = RealtimeMissionCoordinator()

        _ = coordinator.register(name: "place_mission_order", callID: "call-1", arguments: validArguments)

        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        XCTAssertTrue(coordinator.snapshot.hasRedirectedFirstOrderToKiosk)
        XCTAssertTrue(coordinator.takeFunctionCall()?.output.contains(#""success":false"#) == true)
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_secondCall_withValidArguments_placesOrderExactlyOnce() {
        var coordinator = redirectedCoordinator()

        _ = coordinator.register(name: "place_mission_order", callID: "call-2", arguments: validArguments)

        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        XCTAssertTrue(coordinator.takeFunctionCall()?.output.contains(#""success":true"#) == true)
        XCTAssertEqual(coordinator.takeCompletedEvent(), .orderPlaced)
        XCTAssertNil(coordinator.takeCompletedEvent())

        // 이미 주문이 확정된 뒤 같은 함수가 다시 호출돼도 재확정되지 않는다.
        _ = coordinator.register(name: "place_mission_order", callID: "call-3", arguments: validArguments)
        XCTAssertTrue(coordinator.takeFunctionCall()?.output.contains("already placed") == true)
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_secondCall_rejectsWrongQuantity() {
        var coordinator = redirectedCoordinator()

        _ = coordinator.register(
            name: "place_mission_order",
            callID: "call-invalid",
            arguments: #"{"item":"rainbow_macaron_smoothie","quantity":2}"#
        )

        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        XCTAssertNil(coordinator.takeCompletedEvent())
        XCTAssertTrue(coordinator.takeFunctionCall()?.output.contains(#""success":false"#) == true)
    }

    func test_secondCall_rejectsWrongItem() {
        var coordinator = redirectedCoordinator()

        _ = coordinator.register(
            name: "place_mission_order",
            callID: "call-wrong-item",
            arguments: #"{"item":"latte","quantity":1}"#
        )

        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_secondCall_rejectsMalformedJSON() {
        var coordinator = redirectedCoordinator()

        _ = coordinator.register(name: "place_mission_order", callID: "call-bad-json", arguments: "not json")

        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_encounterCleanup_preservesOrderAndRedirectState() {
        var coordinator = redirectedCoordinator()
        coordinator.clearEncounterTransientState()
        XCTAssertTrue(coordinator.snapshot.hasRedirectedFirstOrderToKiosk)

        _ = coordinator.register(name: "place_mission_order", callID: "call-preserved", arguments: validArguments)
        coordinator.clearEncounterTransientState()

        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        XCTAssertEqual(coordinator.takeCompletedEvent(), .orderPlaced)
    }

    func test_immersiveReset_clearsMissionProgress() {
        var coordinator = redirectedCoordinator()
        _ = coordinator.register(name: "place_mission_order", callID: "call-reset", arguments: validArguments)

        coordinator.resetImmersiveProgress()

        XCTAssertTrue(coordinator.snapshot.isPristine)
        XCTAssertNil(coordinator.takeFunctionCall())
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_reportOrderAttempt_firesOnceRegardlessOfItem() {
        var coordinator = RealtimeMissionCoordinator()

        _ = coordinator.register(name: "report_order_attempt", callID: "call-1", arguments: "{}")
        XCTAssertTrue(coordinator.snapshot.hasRedirectedFirstOrderToKiosk)
        XCTAssertTrue(coordinator.takeFunctionCall()?.followUpInstructions.contains("too busy") == true)

        // 이미 리다이렉트가 끝났으면 다시 불러도 키오스크 대사를 반복하지 않는다.
        _ = coordinator.register(name: "report_order_attempt", callID: "call-2", arguments: "{}")
        XCTAssertFalse(coordinator.takeFunctionCall()?.followUpInstructions.contains("too busy") == true)
    }

    func test_reportOrderAttempt_thenPlaceMissionOrder_succeedsOnFirstRealOrderCall() {
        // report_order_attempt가 먼저 리다이렉트를 처리했다면, 뒤이은 place_mission_order의
        // 첫 실제 호출은 또 거절되지 않고 바로 성립해야 한다(이중 리다이렉트 방지).
        var coordinator = RealtimeMissionCoordinator()
        _ = coordinator.register(name: "report_order_attempt", callID: "call-1", arguments: "{}")
        _ = coordinator.takeFunctionCall()

        _ = coordinator.register(name: "place_mission_order", callID: "call-2", arguments: validArguments)

        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        XCTAssertEqual(coordinator.takeCompletedEvent(), .orderPlaced)
    }

    func test_placeMissionOrder_stillRejectsFirstCall_whenReportOrderAttemptWasSkipped() {
        // 모델이 report_order_attempt 호출을 건너뛰고 바로 place_mission_order를 불러도
        // 첫 실제 호출은 여전히 거절된다(안전망).
        var coordinator = RealtimeMissionCoordinator()

        _ = coordinator.register(name: "place_mission_order", callID: "call-1", arguments: validArguments)

        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        XCTAssertNil(coordinator.takeCompletedEvent())
        XCTAssertTrue(coordinator.takeFunctionCall()?.output.contains(#""success":false"#) == true)

        _ = coordinator.register(name: "place_mission_order", callID: "call-2", arguments: validArguments)
        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        XCTAssertEqual(coordinator.takeCompletedEvent(), .orderPlaced)
    }

    func test_secondFunctionCallInSameTurn_isIgnoredToPreserveTheFirstPendingResult() {
        // 모델이 같은 응답 안에서 두 함수를 모두 부르면(지침 위반), pendingFunctionCall이
        // 한 슬롯뿐이라 덮어쓰면 첫 호출의 결과가 API로 전송되지 못한다. 두 번째 호출은
        // 무시되고 첫 호출의 pending 결과가 그대로 보존돼야 한다.
        var coordinator = RealtimeMissionCoordinator()

        _ = coordinator.register(name: "report_order_attempt", callID: "call-1", arguments: "{}")
        _ = coordinator.register(name: "place_mission_order", callID: "call-2", arguments: validArguments)

        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        let pending = coordinator.takeFunctionCall()
        XCTAssertEqual(pending?.callID, "call-1")
    }

    /// 실제 앱 흐름에서는 매 턴이 끝날 때마다 takeFunctionCall()로 pending 결과를 비운다
    /// (finishRealtimeResponse 참고) — 여기서도 드레인해야 다음 register() 호출이 "같은
    /// 턴의 두 번째 함수 호출"로 오인돼 무시되지 않는다.
    private func redirectedCoordinator() -> RealtimeMissionCoordinator {
        var coordinator = RealtimeMissionCoordinator()
        _ = coordinator.register(name: "place_mission_order", callID: "call-1", arguments: validArguments)
        _ = coordinator.takeFunctionCall()
        return coordinator
    }
}
