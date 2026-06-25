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

    func test_orderComplete_yieldsOrderPlacedEvent() async {
        let llm = MockLLM([
            .token("네, 아메리카노요."),
            .intentFragment(#"{"kind":"orderComplete","politeness":2}"#),
            .done,
        ])
        let sut = makeSUT(llm)
        let r = await sut.handle(utterance: "아메리카노 주세요", history: [])
        XCTAssertEqual(r.event, .orderPlaced)
        XCTAssertFalse(r.usedFallback)
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

    func test_trailingFragmentWithoutTerminator_isFlushed() async {
        let llm = MockLLM([.token("네"), .token(" 알겠습니다")], throwAfter: nil)  // 종결부호 없음, throw 없음
        let sut = makeSUT(llm)
        let r = await sut.handle(utterance: "고맙습니다", history: [])
        XCTAssertEqual(r.spokenSentences, ["네 알겠습니다"])
        XCTAssertFalse(r.usedFallback)
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
}
