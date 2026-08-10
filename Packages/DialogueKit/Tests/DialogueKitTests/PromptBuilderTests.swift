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
        XCTAssertTrue(sys.contains("Respond ONLY in everyday spoken Korean"))
        XCTAssertTrue(sys.contains("live face-to-face conversation"))
        XCTAssertTrue(sys.contains("Ask at most one relevant follow-up question"))
        XCTAssertTrue(sys.contains("Do not restart the greeting"))
    }

    func test_dismissiveTone_isInjectedIntoSystem() {
        var c = SocialClimate(); c.rapport = -0.6
        let msgs = PromptBuilder().build(persona: persona, climate: c,
            history: [], userUtterance: "야", turnLimit: 8)
        XCTAssertTrue(msgs.first!.content.contains("hostile"))
    }

    func test_ableistPersona_andKioskRefusal_areExplicit() {
        let ableist = NPCPersona(id: "staff", role: "cafe staff",
            englishSystemBase: "You are staff.", accessibilityAttitude: .ableist)
        let climate = SocialClimate(rapport: ableist.accessibilityAttitude.initialRapport)
        let msgs = PromptBuilder().build(persona: ableist, climate: climate,
            history: [], userUtterance: "키오스크가 너무 높아요", turnLimit: 8,
            orderDecision: .refuseKioskOnly)
        let system = msgs.first!.content
        XCTAssertTrue(system.contains("ableist"))
        XCTAssertTrue(system.contains("kiosk touchscreen is mounted too high"))
        XCTAssertTrue(system.contains("refuseKioskOnly"))
        XCTAssertTrue(system.contains("accepts orders only through the kiosk"))
        XCTAssertTrue(system.contains("죄송 or 미안"))
        XCTAssertTrue(system.contains("Never use slurs"))
    }

    func test_reluctantAcceptance_requiresTakingOrder_andNeverReturningToKiosk() {
        let msgs = PromptBuilder().build(persona: persona, climate: SocialClimate(),
            history: [], userUtterance: "주문 받아주세요", turnLimit: 8,
            orderDecision: .acceptReluctantly)
        let system = msgs.first!.content
        XCTAssertTrue(system.contains("only this once"))
        XCTAssertTrue(system.contains("Do not send them back to the kiosk"))
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

    func test_onlySixRecentTurns_areSent() {
        let history = (0..<16).map { index in
            Message(role: index.isMultiple(of: 2) ? .user : .assistant, content: "m\(index)")
        }
        let msgs = PromptBuilder().build(persona: persona, climate: SocialClimate(),
            history: history, userUtterance: "latest", turnLimit: 30)
        XCTAssertEqual(msgs.count, 14) // system + 최근 12개 + 현재 발화
        XCTAssertEqual(msgs[1].content, "m4")
        XCTAssertEqual(msgs.last?.content, "latest")
    }

    func test_realtimeGuide_prioritizesNaturalConversationOverScripts() {
        let guide = RealtimeConversationGuide().instructions(
            persona: persona,
            climate: SocialClimate(rapport: 0.1)
        )

        XCTAssertTrue(guide.contains("natural everyday Korean"))
        XCTAssertTrue(guide.contains("Listen for meaning"))
        XCTAssertTrue(guide.contains("not trigger words"))
        XCTAssertTrue(guide.contains("Do not follow a fixed script"))
        XCTAssertTrue(guide.contains("Accept interruptions, corrections, topic changes"))
        XCTAssertTrue(guide.contains("After each answer, stop and wait"))
    }

    func test_realtimeGuide_keepsMissionTransitionsDeterministic() {
        let ableist = NPCPersona(
            id: "staff",
            role: "cafe staff",
            englishSystemBase: "You are busy.",
            accessibilityAttitude: .ableist
        )
        let guide = RealtimeConversationGuide().instructions(
            persona: ableist,
            climate: SocialClimate(rapport: ableist.accessibilityAttitude.initialRapport)
        )

        XCTAssertTrue(guide.contains("Begin with an ableist assumption"))
        XCTAssertTrue(guide.contains("instead of repeating a stock refusal"))
        XCTAssertTrue(guide.contains("Call complete_order exactly once"))
        XCTAssertTrue(guide.contains("never call it for silence"))
        XCTAssertTrue(guide.contains("Do not call any tool for greetings"))
    }
}
