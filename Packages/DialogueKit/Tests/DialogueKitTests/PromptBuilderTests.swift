import XCTest
@testable import DialogueKit

final class PromptBuilderTests: XCTestCase {
    private let persona = NPCPersona(id: "staff", role: "cafe staff",
        englishSystemBase: "You are a busy cafe staff member.")

    func test_systemMessage_isFirst_andInEnglish_andDemandsKoreanOutput() {
        let msgs = PromptBuilder().build(persona: persona, climate: SocialClimate(),
            history: [], userUtterance: "아메리카노 주세요", turnLimit: 8)
        XCTAssertEqual(msgs.first?.role, .system)
        let sys = msgs.first!.content
        XCTAssertTrue(sys.contains("You are a busy cafe staff member."))
        XCTAssertTrue(sys.contains("Respond ONLY in Korean"))   // 한국어 출력 강제
        XCTAssertTrue(sys.contains("Keep the first sentence short")) // 첫 문장 짧게(지연↓)
    }

    func test_curtTone_isInjectedIntoSystem() {
        var c = SocialClimate(); c.rapport = -0.6
        let msgs = PromptBuilder().build(persona: persona, climate: c,
            history: [], userUtterance: "야", turnLimit: 8)
        XCTAssertTrue(msgs.first!.content.contains("curt"))
    }

    func test_history_thenUserUtterance_appendedInOrder() {
        let history = [Message(role: .user, content: "안녕"),
                       Message(role: .assistant, content: "어서 오세요")]
        let msgs = PromptBuilder().build(persona: persona, climate: SocialClimate(),
            history: history, userUtterance: "주문할게요", turnLimit: 8)
        XCTAssertEqual(msgs.count, 4) // system + 2 history + 1 user
        XCTAssertEqual(msgs.last, Message(role: .user, content: "주문할게요"))
        XCTAssertEqual(msgs[1], history[0])
    }

    func test_turnLimit_isStatedInSystem() {
        let msgs = PromptBuilder().build(persona: persona, climate: SocialClimate(),
            history: [], userUtterance: "x", turnLimit: 8)
        XCTAssertTrue(msgs.first!.content.contains("8"))
    }
}
