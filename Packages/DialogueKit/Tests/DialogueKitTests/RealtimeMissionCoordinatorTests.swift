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
        XCTAssertTrue(coordinator.takeFunctionCalls().first?.followUpInstructions.contains("원칙적으로 주문을 키오스크에서만 받는다") == true)

        // 이미 리다이렉트가 끝났으면 다시 불러도 키오스크 대사를 반복하지 않는다.
        _ = coordinator.register(name: "report_order_attempt", callID: "call-2", arguments: "{}")
        XCTAssertFalse(coordinator.takeFunctionCalls().first?.followUpInstructions.contains("원칙적으로 주문을 키오스크에서만 받는다") == true)
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
        XCTAssertTrue(pending[0].followUpInstructions.contains("원칙적으로 주문을 키오스크에서만 받는다"))
        // 두 번째(무시된) 호출은 API에 결과만 보내고, 서사에 영향을 주는 지시는 담지 않는다.
        XCTAssertTrue(pending[1].followUpInstructions.isEmpty)
        XCTAssertTrue(pending[1].output.contains(#""success":false"#))
    }

    func test_unknownFunctionName_isRejectedWithoutAffectingMissionState() {
        var coordinator = RealtimeMissionCoordinator()

        _ = coordinator.register(name: "some_other_tool", callID: "call-1", arguments: "{}")

        XCTAssertFalse(coordinator.snapshot.hasRedirectedFirstOrderToKiosk)
        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        let pending = coordinator.takeFunctionCalls()
        XCTAssertTrue(pending.first?.output.contains("unknown function") == true)
    }

    func test_reportOrderAttempt_ignoresItsArguments_evenWhenMalformed() {
        // report_order_attempt는 "무언가를 주문하려 한다"는 사실 자체만 신호이고 품목·수량은
        // 전혀 파싱하지 않는다 — 모델이 이상한 JSON을 넘겨도(혹은 아예 안 넘겨도) 똑같이
        // 동작해야 한다.
        var coordinator = RealtimeMissionCoordinator()

        _ = coordinator.register(name: "report_order_attempt", callID: "call-1", arguments: "not even json {{{")

        XCTAssertTrue(coordinator.snapshot.hasRedirectedFirstOrderToKiosk)
        XCTAssertTrue(coordinator.takeFunctionCalls().first?.output.contains(#""success":true"#) == true)
    }

    func test_reportOrderAttempt_afterOrderAlreadyPlaced_doesNotDisruptState() {
        // 주문이 이미 성립한 뒤 모델이 실수로 report_order_attempt를 다시 불러도(예: 다른
        // 품목을 또 물어보는 상황) 이미 리다이렉트가 끝난 상태라 "이미 기록해 두었다" 안내만
        // 나가고 주문 상태는 그대로여야 한다.
        var coordinator = redirectedCoordinator()
        _ = coordinator.register(name: "place_mission_order", callID: "call-2", arguments: validArguments)
        _ = coordinator.takeFunctionCalls()
        XCTAssertTrue(coordinator.snapshot.orderPlaced)

        _ = coordinator.register(name: "report_order_attempt", callID: "call-3", arguments: "{}")

        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        XCTAssertFalse(coordinator.takeFunctionCalls().first?.followUpInstructions.contains("원칙적으로 주문을 키오스크에서만 받는다") == true)
    }

    func test_secondCall_acceptsExtraUnknownJSONFields() {
        // 모델이 스키마에 없는 필드를 덧붙여도(예: 설명 필드) 알려진 item/quantity만 맞으면
        // 여전히 승인돼야 한다 — 실시간 모델의 JSON 출력이 스키마에 완전히 엄격하지 않을 수
        // 있다.
        var coordinator = redirectedCoordinator()

        _ = coordinator.register(
            name: "place_mission_order",
            callID: "call-extra-field",
            arguments: #"{"item":"rainbow_macaron_smoothie","quantity":1,"note":"방문자가 직접 설명함"}"#
        )

        XCTAssertTrue(coordinator.snapshot.orderPlaced)
        XCTAssertEqual(coordinator.takeCompletedEvent(), .orderPlaced)
    }

    func test_secondCall_rejectsItemNameCaseOrWhitespaceMismatch() {
        // item 매칭은 정확한 문자열 동일성만 본다 — 대소문자나 공백이 다르면 실패한다. 이
        // 엄격함 자체가 의도된 동작인지 확인해 두는 회귀 테스트다(모델이 대문자로 시작하는
        // 식별자를 낼 가능성은 실제로 있다).
        var coordinator = redirectedCoordinator()

        _ = coordinator.register(
            name: "place_mission_order",
            callID: "call-case-mismatch",
            arguments: #"{"item":"Rainbow_Macaron_Smoothie","quantity":1}"#
        )

        XCTAssertFalse(coordinator.snapshot.orderPlaced)
        XCTAssertTrue(coordinator.takeFunctionCalls().first?.output.contains(#""success":false"#) == true)
    }

    func test_visitorTurnCounter_survivesEncounterCleanup() {
        // clearEncounterTransientState()는 Realtime 연결만 끊길 때 호출된다(예: 대화 잠깐
        // 끊겼다 재연결). 관대화 기준으로 쓰이는 방문자 턴 수는 같은 카페 방문 동안 이어져야
        // 하므로 이 정리로 리셋되면 안 된다.
        var coordinator = RealtimeMissionCoordinator()
        _ = coordinator.register(name: "report_order_attempt", callID: "call-1", arguments: "{}")
        _ = coordinator.takeFunctionCalls()
        coordinator.registerVisitorTurn()
        coordinator.registerVisitorTurn()
        XCTAssertEqual(coordinator.snapshot.visitorTurnsSinceRedirect, 2)

        coordinator.clearEncounterTransientState()

        XCTAssertEqual(coordinator.snapshot.visitorTurnsSinceRedirect, 2)
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
