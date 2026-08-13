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

    func test_rainbowSmoothie_withBarrier_isConcreteOrderAndPreservesBarrierSignal() {
        let utterance = "키오스크 화면에 손이 안 닿아서 레인보우 스무디 주세요"

        XCTAssertEqual(router.infer(from: utterance).kind, .orderComplete)
        XCTAssertTrue(router.describesKioskAccessBarrier(in: utterance))
    }

    func test_onlyRainbowSmoothie_isMissionOrder() {
        XCTAssertEqual(router.infer(from: "레인보우스무디 하나 주세요").kind, .orderComplete)
        XCTAssertEqual(router.infer(from: "아메리카노 주세요").kind, .orderRequest)
        XCTAssertEqual(router.infer(from: "딸기 스무디 주세요").kind, .orderRequest)
        XCTAssertEqual(router.infer(from: "레인보우 스무디 두 잔 주세요").kind, .orderRequest)
        XCTAssertEqual(router.infer(from: "레인보우 스무디 12잔 주세요").kind, .orderRequest)
        XCTAssertEqual(router.infer(from: "레인보우 스무디 말고 라떼 주세요").kind, .orderRequest)
    }

    func test_realtimeMissionOrderArguments_requireCanonicalItemAndSingleQuantity() {
        XCTAssertTrue(
            RainbowSmoothieMissionOrder.validates(
                toolArgumentsJSON: #"{"item":"rainbow_smoothie","quantity":1}"#
            )
        )
        XCTAssertFalse(
            RainbowSmoothieMissionOrder.validates(
                toolArgumentsJSON: #"{"item":"americano","quantity":1}"#
            )
        )
        XCTAssertFalse(
            RainbowSmoothieMissionOrder.validates(
                toolArgumentsJSON: #"{"item":"rainbow_smoothie","quantity":2}"#
            )
        )
        XCTAssertFalse(
            RainbowSmoothieMissionOrder.validates(toolArgumentsJSON: "not-json")
        )
    }

    func test_realtimeMissionProgress_requiresTranscriptEvidenceAndPersonalityAttempts() {
        var cautious = RainbowSmoothieMissionProgress(personality: .cautious)

        cautious.observe(userTranscript: "레인보우 스무디 주세요")
        XCTAssertFalse(cautious.canComplete)
        cautious.observe(userTranscript: "키오스크가 높아서 손이 안 닿아요")
        XCTAssertFalse(cautious.canComplete)
        cautious.observe(userTranscript: "진짜 안 닿아요. 직접 받아주세요")
        XCTAssertTrue(cautious.canComplete)

        cautious.reset()
        cautious.observe(userTranscript: "키오스크가 높아서 손이 안 닿으니 레인보우 스무디 두 잔 주세요")
        cautious.observe(userTranscript: "그래도 직접 받아주세요")
        XCTAssertFalse(cautious.canComplete)

        var hurried = RainbowSmoothieMissionProgress(personality: .hurried)
        hurried.observe(userTranscript: "키오스크가 높아서 손이 안 닿으니 레인보우 스무디 주세요")
        XCTAssertTrue(hurried.canComplete)
        hurried.observe(userTranscript: "아니요, 아메리카노로 바꿀게요")
        XCTAssertFalse(hurried.canComplete)
    }

    func test_realtimeMissionCoordinator_rejectedOrderReturnsOneNonTerminalFollowUp() throws {
        var coordinator = RealtimeMissionCoordinator(personality: .blunt)
        coordinator.observe(userTranscript: "키오스크가 너무 높아서 손이 안 닿아요")
        coordinator.observe(userTranscript: "레인보우 스무디 한 잔 주세요")

        let immediateEvent = coordinator.register(
            name: "complete_order",
            callID: "call-rejected",
            arguments: #"{"item":"rainbow_smoothie","quantity":1}"#
        )
        let functionCall = try XCTUnwrap(coordinator.takeFunctionCall())

        XCTAssertNil(immediateEvent)
        XCTAssertTrue(functionCall.output.contains(#""success":false"#))
        XCTAssertTrue(functionCall.followUpInstructions.contains("retry any tool"))
        XCTAssertNil(coordinator.takeFunctionCall())
        XCTAssertNil(coordinator.takeCompletedEvent())
    }

    func test_realtimeMissionCoordinator_validOrderCompletesAfterFollowUp() throws {
        var coordinator = RealtimeMissionCoordinator(personality: .blunt)
        coordinator.observe(userTranscript: "키오스크가 너무 높아서 손이 안 닿아요")
        coordinator.observe(userTranscript: "그래도 직접 주문 받아주세요")
        coordinator.observe(userTranscript: "레인보우 스무디 한 잔 주세요")

        _ = coordinator.register(
            name: "complete_order",
            callID: "call-success",
            arguments: #"{"item":"rainbow_smoothie","quantity":1}"#
        )
        let functionCall = try XCTUnwrap(coordinator.takeFunctionCall())

        XCTAssertTrue(functionCall.output.contains(#""success":true"#))
        XCTAssertEqual(coordinator.takeCompletedEvent(), .orderPlaced)
        XCTAssertNil(coordinator.takeCompletedEvent())
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

    func test_orderComplete_mapsTo_orderPlaced() {
        XCTAssertEqual(router.route(DialogueIntent(kind: .orderComplete)), .orderPlaced)
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
