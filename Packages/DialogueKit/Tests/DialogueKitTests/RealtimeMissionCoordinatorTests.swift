import XCTest
@testable import DialogueKit

final class RealtimeMissionCoordinatorTests: XCTestCase {
    private let validArguments = #"{"item":"rainbow_macaron_smoothie","quantity":1}"#

    func test_firstCall_isAlwaysRedirectedToKiosk_regardlessOfValidity() {
        var coordinator = RealtimeMissionCoordinator()

        _ = coordinator.register(name: "place_mission_order", callID: "call-1", arguments: validArguments)

        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        XCTAssertTrue(coordinator.snapshot.hasRedirectedFirstOrderToKiosk)
        XCTAssertTrue(coordinator.takeFunctionCalls().first?.output.contains(#""success":false"#) == true)
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_secondCall_withValidArguments_placesOrderExactlyOnce() {
        var coordinator = redirectedCoordinator()

        _ = coordinator.register(name: "place_mission_order", callID: "call-2", arguments: validArguments)

        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        XCTAssertTrue(coordinator.takeFunctionCalls().first?.output.contains(#""success":true"#) == true)
        XCTAssertEqual(coordinator.takeCompletedEvent(), .orderPlaced)
        XCTAssertNil(coordinator.takeCompletedEvent())

        // 이미 주문이 확정된 뒤 같은 함수가 다시 호출돼도 재확정되지 않는다.
        _ = coordinator.register(name: "place_mission_order", callID: "call-3", arguments: validArguments)
        XCTAssertTrue(coordinator.takeFunctionCalls().first?.output.contains("already placed") == true)
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
        XCTAssertTrue(coordinator.takeFunctionCalls().first?.output.contains(#""success":false"#) == true)
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
        XCTAssertTrue(coordinator.takeFunctionCalls().isEmpty)
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_reportOrderAttempt_firesOnceRegardlessOfItem() {
        var coordinator = RealtimeMissionCoordinator()

        _ = coordinator.register(name: "report_order_attempt", callID: "call-1", arguments: "{}")
        XCTAssertTrue(coordinator.snapshot.hasRedirectedFirstOrderToKiosk)
        XCTAssertTrue(coordinator.takeFunctionCalls().first?.followUpInstructions.contains("너무 바빠서 응대할 수 없다") == true)

        // 이미 리다이렉트가 끝났으면 다시 불러도 키오스크 대사를 반복하지 않는다.
        _ = coordinator.register(name: "report_order_attempt", callID: "call-2", arguments: "{}")
        XCTAssertFalse(coordinator.takeFunctionCalls().first?.followUpInstructions.contains("너무 바빠서 응대할 수 없다") == true)
    }

    func test_registerVisitorTurn_onlyCountsAfterRedirectAndBeforeOrderPlaced() {
        var coordinator = RealtimeMissionCoordinator()

        // 리다이렉트 전에는 세지 않는다.
        coordinator.registerVisitorTurn()
        XCTAssertEqual(coordinator.snapshot.visitorTurnsSinceRedirect, 0)

        _ = coordinator.register(name: "report_order_attempt", callID: "call-1", arguments: "{}")
        _ = coordinator.takeFunctionCalls() // 매 턴 끝에 pending 결과를 비우는 실제 앱 흐름을 흉내낸다.
        coordinator.registerVisitorTurn()
        coordinator.registerVisitorTurn()
        XCTAssertEqual(coordinator.snapshot.visitorTurnsSinceRedirect, 2)

        // 주문이 성립한 뒤에는 더 이상 늘지 않는다.
        _ = coordinator.register(name: "place_mission_order", callID: "call-2", arguments: validArguments)
        _ = coordinator.takeFunctionCalls()
        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        coordinator.registerVisitorTurn()
        XCTAssertEqual(coordinator.snapshot.visitorTurnsSinceRedirect, 2)
    }

    func test_immersiveReset_alsoClearsVisitorTurnCounter() {
        var coordinator = RealtimeMissionCoordinator()
        _ = coordinator.register(name: "report_order_attempt", callID: "call-1", arguments: "{}")
        coordinator.registerVisitorTurn()

        coordinator.resetImmersiveProgress()

        XCTAssertEqual(coordinator.snapshot.visitorTurnsSinceRedirect, 0)
    }

    func test_reportOrderAttempt_thenPlaceMissionOrder_succeedsOnFirstRealOrderCall() {
        // report_order_attempt가 먼저 리다이렉트를 처리했다면, 뒤이은 place_mission_order의
        // 첫 실제 호출은 또 거절되지 않고 바로 성립해야 한다(이중 리다이렉트 방지).
        var coordinator = RealtimeMissionCoordinator()
        _ = coordinator.register(name: "report_order_attempt", callID: "call-1", arguments: "{}")
        _ = coordinator.takeFunctionCalls()

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
        XCTAssertTrue(coordinator.takeFunctionCalls().first?.output.contains(#""success":false"#) == true)

        _ = coordinator.register(name: "place_mission_order", callID: "call-2", arguments: validArguments)
        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        XCTAssertEqual(coordinator.takeCompletedEvent(), .orderPlaced)
    }

    func test_secondFunctionCallInSameTurn_isRejectedButStillCompletedForTheAPI() {
        // 모델이 같은 응답 안에서 두 함수를 모두 부르면(지침 위반), 실제 업무 로직은 첫
        // 호출에만 적용한다. 그렇다고 두 번째 호출을 그냥 버리면 그 callID에 대한 output이
        // API로 영영 전송되지 않아 대화 상태가 응답 없는 tool call을 매단 채로 꼬인다 —
        // 그래서 두 번째 호출도 거절 결과로 큐에 남아 함께 드레인돼야 한다.
        var coordinator = RealtimeMissionCoordinator()

        _ = coordinator.register(name: "report_order_attempt", callID: "call-1", arguments: "{}")
        _ = coordinator.register(name: "place_mission_order", callID: "call-2", arguments: validArguments)

        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        let pending = coordinator.takeFunctionCalls()
        XCTAssertEqual(pending.map(\.callID), ["call-1", "call-2"])
        XCTAssertTrue(pending[0].followUpInstructions.contains("너무 바빠서 응대할 수 없다"))
        // 두 번째(무시된) 호출은 API에 결과만 보내고, 서사에 영향을 주는 지시는 담지 않는다.
        XCTAssertTrue(pending[1].followUpInstructions.isEmpty)
        XCTAssertTrue(pending[1].output.contains(#""success":false"#))
    }

    /// 실제 앱 흐름에서는 매 턴이 끝날 때마다 takeFunctionCalls()로 pending 결과를 비운다
    /// (finishRealtimeResponse 참고) — 여기서도 드레인해야 다음 register() 호출이 "같은
    /// 턴의 두 번째 함수 호출"로 오인돼 무시되지 않는다.
    private func redirectedCoordinator() -> RealtimeMissionCoordinator {
        var coordinator = RealtimeMissionCoordinator()
        _ = coordinator.register(name: "place_mission_order", callID: "call-1", arguments: validArguments)
        _ = coordinator.takeFunctionCalls()
        return coordinator
    }
}
