import XCTest
@testable import DialogueKit

// 테스트용 목 LLM: 주어진 이벤트 시퀀스를 그대로 흘리거나 에러를 던진다.
private struct MockLLM: LLMClient {
    let events: [LLMEvent]
    let throwAfter: Int?   // n개 방출 후 throw
    init(_ events: [LLMEvent], throwAfter: Int? = nil) { self.events = events; self.throwAfter = throwAfter }
    func stream(messages: [Message]) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { cont in
            for (i, e) in events.enumerated() {
                if let t = throwAfter, i == t { cont.finish(throwing: NSError(domain: "net", code: -1)); return }
                cont.yield(e)
            }
            cont.finish()
        }
    }
}

final class DialogueOrchestratorTests: XCTestCase {
    private func makeSUT(_ llm: LLMClient, turnLimit: Int = 8) -> DialogueOrchestrator {
        DialogueOrchestrator(
            persona: NPCPersona(id: "staff", role: "cafe staff", englishSystemBase: "You are staff."),
            climate: SocialClimate(),
            llm: llm,
            guardian: SafetyGuard(bannedKeywords: ["bomb"], maxTurns: turnLimit),
            cache: DialogueCache(lines: [
                .timeout: CannedLine(text: "잠시만요…", audioKey: "timeout_ko"),
                .blockedContent: CannedLine(text: "주문을 도와드릴게요.", audioKey: "blocked_ko"),
                .orderConfirm: CannedLine(text: "한 잔 주문됐어요.", audioKey: "order-confirm_ko"),
                .fulfillmentUnavailable: CannedLine(
                    text: "죄송하지만 현재 레인보우 스무디를 제공해 드리기 어려워요.",
                    audioKey: "fulfillment-unavailable_ko"),
            ]),
            turnLimit: turnLimit)
    }

    func test_happyPath_collectsSentences_andRoutesIntent() async {
        let llm = MockLLM([
            .token("어서 오세요"), .token("."),
            .token(" 무엇을 드릴까요"), .token("?"),
            .intentFragment(#"{"kind":"smalltalk"}"#),
            .done,
        ])
        let sut = makeSUT(llm)
        let r = await sut.handle(utterance: "안녕하세요", history: [])
        XCTAssertEqual(r.spokenSentences, ["어서 오세요.", " 무엇을 드릴까요?"])
        XCTAssertNil(r.event)            // smalltalk → 이벤트 없음
        XCTAssertFalse(r.usedFallback)
    }

    func test_rainbowSmoothieOrder_yieldsOrderPlacedEvent() async {
        let llm = MockLLM([
            .token("네, 레인보우 스무디요."),
            .done,
        ])
        let sut = makeSUT(llm)
        let r = await sut.handle(
            utterance: "키오스크 화면에 손이 안 닿아서 레인보우 마카롱 스무디 한 잔 주세요",
            history: []
        )
        XCTAssertEqual(r.event, .orderPlaced)
        XCTAssertFalse(r.usedFallback)
    }

    func test_preparingFulfillment_cannotPublishAnotherOrderPlacedEvent() async {
        let sut = makeSUT(MockLLM([.token("이미 주문 상태를 확인해 드릴게요."), .done]))

        let result = await sut.handle(
            utterance: "레인보우 스무디 한 잔 더 주문할게요",
            history: [],
            fulfillmentContext: .preparing
        )

        XCTAssertNil(result.event)
        XCTAssertFalse(result.usedFallback)
    }

    func test_completedOrder_preservesEventWhenGenerationFails() async {
        let sut = makeSUT(MockLLM([.token("생성되지 않음")], throwAfter: 0))

        let result = await sut.handle(
            utterance: "키오스크 화면에 손이 안 닿아서 레인보우 마카롱 스무디 한 잔 주세요",
            history: []
        )

        XCTAssertEqual(result.event, .orderPlaced)
        XCTAssertEqual(result.spokenSentences, ["한 잔 주문됐어요."])
        XCTAssertTrue(result.usedFallback)
    }

    func test_failedFulfillment_orderAttemptUsesUnavailableFallbackWhenGenerationThrows() async {
        let sut = makeSUT(MockLLM([.token("생성되지 않음")], throwAfter: 0))

        let result = await sut.handle(
            utterance: "레인보우 스무디 한 잔 다시 주문할게요",
            history: [],
            fulfillmentContext: .failed
        )

        XCTAssertEqual(
            result.spokenSentences,
            ["죄송하지만 현재 레인보우 스무디를 제공해 드리기 어려워요."])
        XCTAssertTrue(result.usedFallback)
        XCTAssertNil(result.event)
    }

    func test_failedFulfillment_statusAttemptUsesUnavailableFallbackForEmptyOutput() async {
        let sut = makeSUT(MockLLM([.done]))

        let result = await sut.handle(
            utterance: "제 스무디 준비 상태가 어떻게 됐어요?",
            history: [],
            fulfillmentContext: .failed
        )

        XCTAssertEqual(
            result.spokenSentences,
            ["죄송하지만 현재 레인보우 스무디를 제공해 드리기 어려워요."])
        XCTAssertTrue(result.usedFallback)
        XCTAssertNil(result.event)
    }

    func test_ableistStaff_refusesTwice_thenReluctantlyAcceptsThirdOrderRequest() async {
        let sut = DialogueOrchestrator(
            persona: NPCPersona(id: "staff", role: "cafe staff", englishSystemBase: "You are staff.",
                                accessibilityAttitude: .ableist,
                                clerkPersonality: .blunt),
            llm: MockLLM([.token("응답."), .done]),
            guardian: SafetyGuard(bannedKeywords: [], maxTurns: 8),
            cache: DialogueCache(lines: [.timeout: CannedLine(text: "잠시만요…", audioKey: "t")]),
            turnLimit: 8)

        let first = await sut.handle(utterance: "키오스크가 너무 높아서 주문하기 어려워요", history: [])
        let second = await sut.handle(utterance: "아메리카노 주문 받아주세요", history: [])
        let third = await sut.handle(utterance: "직접 주문 좀 받아주세요", history: [])
        let fourth = await sut.handle(utterance: "그럼 레인보우 스무디 주세요", history: [])
        let fifth = await sut.handle(utterance: "한 잔이요", history: [])

        XCTAssertNil(first.event)
        XCTAssertNil(second.event)
        XCTAssertNil(third.event)
        XCTAssertNil(fourth.event)
        XCTAssertEqual(fifth.event, .orderPlaced)
    }

    func test_genericAcceptedOrder_asksForItemBeforeCompleting() async {
        let sut = makeSUT(MockLLM([.token("네."), .done]))

        let request = await sut.handle(
            utterance: "키오스크가 너무 높아서 손이 안 닿아 주문하고 싶어요",
            history: []
        )
        let otherItem = await sut.handle(utterance: "아메리카노 주세요", history: [])
        let missionItem = await sut.handle(utterance: "레인보우 스무디 주세요", history: [])
        let quantity = await sut.handle(utterance: "한 잔이요", history: [])

        XCTAssertNil(request.event)
        XCTAssertNil(otherItem.event)
        XCTAssertNil(missionItem.event)
        XCTAssertEqual(quantity.event, .orderPlaced)
    }

    func test_warmRapport_doesNotSkipBluntPersonalityResistance() async {
        let sut = DialogueOrchestrator(
            persona: NPCPersona(id: "staff", role: "cafe staff", englishSystemBase: "You are staff.",
                                accessibilityAttitude: .ableist,
                                clerkPersonality: .blunt),
            climate: SocialClimate(rapport: 0.25),
            llm: MockLLM([.token("주문 도와드릴게요."), .done]),
            guardian: SafetyGuard(bannedKeywords: [], maxTurns: 8),
            cache: DialogueCache(lines: [:]),
            turnLimit: 8)

        let result = await sut.handle(
            utterance: "키오스크 화면에 손이 안 닿아서 아메리카노 한 잔 주세요",
            history: []
        )
        XCTAssertNil(result.event)
    }

    func test_streamError_fallsBackToCannedTimeout_doesNotThrow() async {
        let llm = MockLLM([.token("어서"), .token(" 오세요")], throwAfter: 1)  // "어서" 방출 후 throw
        let sut = makeSUT(llm)
        let r = await sut.handle(utterance: "안녕", history: [])
        XCTAssertTrue(r.usedFallback)
        XCTAssertEqual(r.spokenSentences, ["잠시만요…"])
        XCTAssertNil(r.event)
    }

    func test_bannedInput_isBlocked_usesBlockedCanned() async {
        let sut = makeSUT(MockLLM([.done]))
        let r = await sut.handle(utterance: "bomb 줘", history: [])
        XCTAssertTrue(r.usedFallback)
        XCTAssertEqual(r.spokenSentences, ["주문을 도와드릴게요."])
    }

    func test_politeUtterance_raisesClimate() async {
        let sut = makeSUT(MockLLM([.token("네."), .done]))
        _ = await sut.handle(utterance: "안녕하세요, 부탁드려요 감사합니다", history: [])
        let rapport = await sut.climate.rapport
        XCTAssertGreaterThan(rapport, 0)
    }

    func test_observePlayerTurn_updatesClimateWithoutGeneratingResponse() async {
        let sut = makeSUT(MockLLM([.done]))

        let politeClimate = await sut.observePlayerTurn("부탁드려요")
        let hostileClimate = await sut.observePlayerTurn("닥쳐")

        XCTAssertEqual(politeClimate.rapport, 0.15, accuracy: 0.0001)
        XCTAssertEqual(hostileClimate.rapport, -0.15, accuracy: 0.0001)
        XCTAssertEqual(hostileClimate.tone, .neutral)
    }

    func test_trailingFragmentWithoutTerminator_isFlushed() async {
        let llm = MockLLM([.token("네"), .token(" 알겠습니다")], throwAfter: nil)  // 종결부호 없음, throw 없음
        let sut = makeSUT(llm)
        let r = await sut.handle(utterance: "고맙습니다", history: [])
        XCTAssertEqual(r.spokenSentences, ["네 알겠습니다"])
        XCTAssertFalse(r.usedFallback)
    }

    func test_completedSentence_isEmittedBeforeStreamEnds() async {
        final class Box: @unchecked Sendable { var values: [String] = [] }
        let box = Box()
        let sut = makeSUT(MockLLM([.token("첫 문장."), .token(" 둘째 문장."), .done]))
        let result = await sut.handle(utterance: "안녕하세요", history: [], onSentence: {
            box.values.append($0)
        })
        XCTAssertEqual(box.values, ["첫 문장.", " 둘째 문장."])
        XCTAssertEqual(result.spokenSentences, box.values)
    }

    func test_personaAttitude_setsInitialRapport_whenClimateIsOmitted() async {
        let persona = NPCPersona(id: "staff", role: "staff", englishSystemBase: "You are staff.",
                                 accessibilityAttitude: .ableist)
        let sut = DialogueOrchestrator(
            persona: persona,
            llm: MockLLM([.token("네."), .done]),
            guardian: SafetyGuard(bannedKeywords: [], maxTurns: 2),
            cache: DialogueCache(lines: [:]),
            turnLimit: 2)
        let rapport = await sut.climate.rapport
        XCTAssertEqual(rapport, -0.45, accuracy: 0.0001)
    }

    func test_turnLimitReached_returnsTurnLimitFallback() async {
        let sut = DialogueOrchestrator(
            persona: NPCPersona(id: "staff", role: "cafe staff", englishSystemBase: "You are staff."),
            climate: SocialClimate(),
            llm: MockLLM([.token("네."), .done]),
            guardian: SafetyGuard(bannedKeywords: [], maxTurns: 1),
            cache: DialogueCache(lines: [
                .turnLimitReached: CannedLine(text: "이만 가볼게요.", audioKey: "turnlimit_ko"),
            ]),
            turnLimit: 1)
        _ = await sut.handle(utterance: "안녕하세요", history: [])    // turn 1 ok
        let r = await sut.handle(utterance: "한 잔 더요", history: [])  // turn 2 → over cap
        XCTAssertTrue(r.usedFallback)
        XCTAssertEqual(r.spokenSentences, ["이만 가볼게요."])
    }

    func test_beginEncounter_resetsTurnLimit_butKeepsOrderAttempts() async {
        let sut = DialogueOrchestrator(
            persona: NPCPersona(id: "staff", role: "cafe staff", englishSystemBase: "You are staff.",
                                accessibilityAttitude: .ableist,
                                clerkPersonality: .blunt),
            llm: MockLLM([.token("응답."), .done]),
            guardian: SafetyGuard(bannedKeywords: [], maxTurns: 1),
            cache: DialogueCache(lines: [
                .turnLimitReached: CannedLine(text: "대화 종료", audioKey: "turnlimit"),
            ]),
            turnLimit: 1)

        let first = await sut.handle(
            utterance: "키오스크가 높아서 손이 안 닿으니 아메리카노 주문 받아주세요",
            history: []
        )
        let blocked = await sut.handle(utterance: "다시 부탁드려요", history: [])
        await sut.beginEncounter()
        let second = await sut.handle(
            utterance: "키오스크가 높아서 손이 안 닿으니 아메리카노 주문 받아주세요",
            history: []
        )
        await sut.beginEncounter()
        let third = await sut.handle(
            utterance: "키오스크가 높아서 손이 안 닿으니 레인보우 스무디 한 잔 주문 받아주세요",
            history: []
        )

        XCTAssertNil(first.event)
        XCTAssertTrue(blocked.usedFallback)
        XCTAssertNil(second.event)
        XCTAssertEqual(third.event, .orderPlaced)
    }

    func test_personalityControlsHowManyRelevantAttemptsPrecedeAcceptance() async {
        let expectedAttempts: [(ClerkPersonality, Int)] = [
            (.hurried, 1),
            (.chatty, 1),
            (.cautious, 2),
            (.blunt, 3),
        ]

        for (personality, acceptanceAttempt) in expectedAttempts {
            let sut = DialogueOrchestrator(
                persona: NPCPersona(
                    id: "staff",
                    role: "cafe staff",
                    englishSystemBase: "You are staff.",
                    accessibilityAttitude: .ableist,
                    clerkPersonality: personality
                ),
                llm: MockLLM([.token("응답."), .done]),
                guardian: SafetyGuard(bannedKeywords: [], maxTurns: 8),
                cache: DialogueCache(lines: [:]),
                turnLimit: 8
            )

            for attempt in 1...acceptanceAttempt {
                let result = await sut.handle(
                    utterance: "키오스크가 높아서 손이 안 닿으니 레인보우 스무디 주세요",
                    history: []
                )
                XCTAssertNil(result.event, "\(personality) completed before quantity on attempt \(attempt)")
            }
            let quantity = await sut.handle(utterance: "한 잔이요", history: [])
            XCTAssertEqual(quantity.event, .orderPlaced, "\(personality) did not complete after quantity")
        }
    }

    func test_cautiousClerk_acceptsShortInsistenceWithoutRepeatedKioskWord() async {
        let sut = DialogueOrchestrator(
            persona: NPCPersona(
                id: "staff",
                role: "cafe staff",
                englishSystemBase: "You are staff.",
                accessibilityAttitude: .ableist,
                clerkPersonality: .cautious
            ),
            llm: MockLLM([.token("응답."), .done]),
            guardian: SafetyGuard(bannedKeywords: [], maxTurns: 8),
            cache: DialogueCache(lines: [:]),
            turnLimit: 8
        )

        let explanation = await sut.handle(
            utterance: "키오스크 화면이 높아서 손이 안 닿아요",
            history: []
        )
        let insistence = await sut.handle(utterance: "진짜 안 닿아요", history: [])
        let order = await sut.handle(utterance: "레인보우 스무디 주세요", history: [])
        let quantity = await sut.handle(utterance: "한 잔이요", history: [])

        XCTAssertNil(explanation.event)
        XCTAssertNil(insistence.event)
        XCTAssertNil(order.event)
        XCTAssertEqual(quantity.event, .orderPlaced)
    }
}
