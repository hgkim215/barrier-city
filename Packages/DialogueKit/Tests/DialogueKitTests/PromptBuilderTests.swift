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
        XCTAssertTrue(guide.contains("Korean is the ONLY language"))
        XCTAssertTrue(guide.contains("Never answer in English or switch languages"))
        XCTAssertTrue(guide.contains("including the first greeting"))
        XCTAssertTrue(guide.contains("Listen for meaning"))
        XCTAssertTrue(guide.contains("not trigger words"))
        XCTAssertTrue(guide.contains("do not recite a"))
        XCTAssertTrue(guide.contains("fixed script"))
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

        XCTAssertTrue(guide.contains("Assume the standard kiosk process"))
        XCTAssertTrue(guide.contains("personality-specific acceptance timing"))
        XCTAssertTrue(guide.contains("There is no order"))
        XCTAssertTrue(guide.contains("completion tool"))
        XCTAssertTrue(guide.contains("never call it for silence"))
        XCTAssertTrue(guide.contains("Do not call any tool for greetings"))
    }

    func test_prompts_defineRainbowSmoothieAsMissionOrder() {
        let messages = PromptBuilder().build(
            persona: persona,
            climate: SocialClimate(),
            history: [],
            userUtterance: "주문할게요",
            turnLimit: 8
        )
        let realtime = RealtimeConversationGuide().instructions(
            persona: persona,
            climate: SocialClimate()
        )

        XCTAssertTrue(messages.first!.content.contains("Rainbow Smoothie"))
        XCTAssertTrue(messages.first!.content.contains("레인보우 스무디"))
        XCTAssertTrue(messages.first!.content.contains("레인보우 마카롱 스무디"))
        XCTAssertTrue(messages.first!.content.contains("Do not mark a different menu item"))
        XCTAssertTrue(realtime.contains("Rainbow Smoothie"))
        XCTAssertTrue(realtime.contains("레인보우 마카롱 스무디"))
    }

    func test_clerkPersonality_isExplicitInLegacyAndRealtimePrompts() {
        let chatty = NPCPersona(
            id: "staff",
            role: "cafe staff",
            englishSystemBase: "You are staff.",
            accessibilityAttitude: .ableist,
            clerkPersonality: .chatty
        )
        let messages = PromptBuilder().build(
            persona: chatty,
            climate: SocialClimate(),
            history: [],
            userUtterance: "안녕하세요",
            turnLimit: 8
        )
        let realtime = RealtimeConversationGuide().instructions(
            persona: chatty,
            climate: SocialClimate()
        )

        XCTAssertTrue(messages.first!.content.contains("Clerk personality: chatty"))
        XCTAssertTrue(messages.first!.content.contains("sociable and expressive"))
        XCTAssertTrue(realtime.contains("Clerk personality: chatty"))
        XCTAssertTrue(realtime.contains("clearly audible in word choice"))
    }

    func test_realtimeGuide_requiresKioskOpeningBeforeBarrierIsExplained() {
        let guide = RealtimeConversationGuide().instructions(
            persona: persona,
            climate: SocialClimate()
        )

        XCTAssertTrue(RealtimeConversationGuide.openingInstructions.contains("# Conversation stage"))
        XCTAssertTrue(RealtimeConversationGuide.openingInstructions.contains("# Response goal"))
        XCTAssertTrue(RealtimeConversationGuide.openingInstructions.contains("direct them to use the kiosk"))
        XCTAssertTrue(RealtimeConversationGuide.openingInstructions.contains("Do not use a fixed stock script"))
        XCTAssertFalse(RealtimeConversationGuide.openingInstructions.contains("Speak ONLY this exact"))
        XCTAssertTrue(guide.contains("# Required conversation flow"))
        XCTAssertTrue(guide.contains("private scene context"))
        XCTAssertTrue(guide.contains("explaining an access barrier"))
        XCTAssertTrue(guide.contains("Do not ask for an item"))
        XCTAssertTrue(guide.contains("barrier explanation only determines"))
        XCTAssertTrue(guide.contains("ask only how many cups"))
    }

    func test_collectionDecision_separatesBarrierAcceptance_item_andQuantity() {
        let askQuantity = PromptBuilder().build(
            persona: persona,
            climate: SocialClimate(),
            history: [],
            userUtterance: "레인보우 스무디 주세요",
            turnLimit: 8,
            orderDecision: .acceptDirectly,
            orderCollectionDecision: .askQuantity
        ).first!.content
        let complete = PromptBuilder().build(
            persona: persona,
            climate: SocialClimate(),
            history: [],
            userUtterance: "한 잔이요",
            turnLimit: 8,
            orderDecision: .acceptDirectly,
            orderCollectionDecision: .completeOrder
        ).first!.content

        XCTAssertTrue(askQuantity.contains("QUANTITY=missing"))
        XCTAssertTrue(askQuantity.contains("Ask naturally how many cups"))
        XCTAssertTrue(askQuantity.contains("Barrier explanation only opens counter ordering"))
        XCTAssertTrue(askQuantity.contains("주문 처리 중"))
        XCTAssertTrue(complete.contains("ORDER_COMPLETE=true"))
        XCTAssertTrue(complete.contains("TERMINAL_RESPONSE=true"))
        XCTAssertTrue(complete.contains("vary the wording"))
        XCTAssertTrue(complete.contains("app will close the conversation"))
        XCTAssertTrue(complete.contains("The order is already complete, not pending"))
        XCTAssertFalse(askQuantity.contains("몇 잔이요?"))
        XCTAssertFalse(complete.contains("주문 완료됐습니다"))
    }

    func test_realtimeGuide_definesDistinctPersonalityAcceptanceTiming() {
        let expectedRules: [(ClerkPersonality, String)] = [
            (.hurried, "accept the verbal order immediately because arguing would waste time"),
            (.chatty, "accept the verbal order immediately"),
            (.cautious, "ask one skeptical verification question"),
            (.blunt, "On the first two relevant requests or explanations"),
        ]

        for (personality, expected) in expectedRules {
            let personalityPersona = NPCPersona(
                id: "staff",
                role: "cafe staff",
                englishSystemBase: "You are staff.",
                accessibilityAttitude: .ableist,
                clerkPersonality: personality
            )
            let guide = RealtimeConversationGuide().instructions(
                persona: personalityPersona,
                climate: SocialClimate()
            )

            XCTAssertTrue(guide.contains(expected), "Missing rule for \(personality)")
        }
    }

    func test_legacyPrompt_keepsPersonalityTimingAboveWarmRapport() {
        let blunt = NPCPersona(
            id: "staff",
            role: "cafe staff",
            englishSystemBase: "You are staff.",
            accessibilityAttitude: .ableist,
            clerkPersonality: .blunt
        )
        let messages = PromptBuilder().build(
            persona: blunt,
            climate: SocialClimate(rapport: 0.8),
            history: [],
            userUtterance: "키오스크에 손이 안 닿아요",
            turnLimit: 8,
            orderDecision: .refuseKioskOnly
        )

        XCTAssertTrue(messages.first!.content.contains("Follow the personality rule's acceptance timing"))
        XCTAssertTrue(messages.first!.content.contains("Once verbal service is accepted"))
    }
}
