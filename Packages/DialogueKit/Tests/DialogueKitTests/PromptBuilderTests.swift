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
        XCTAssertTrue(guide.contains("Respond directly to the visitor's latest meaning"))
        XCTAssertTrue(guide.contains("genuine small talk"))
        XCTAssertTrue(guide.contains("topic changes"))
        XCTAssertTrue(guide.contains("fixed script"))
        XCTAssertTrue(guide.contains("Stop after each answer and wait"))
        XCTAssertTrue(guide.contains("running out of beans"))
    }

    func test_realtimeGuide_keepsOnlyMissionOrderDeterministic() {
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

        XCTAssertTrue(guide.contains("Ordinary dialogue never changes game state"))
        XCTAssertTrue(guide.contains("only function-backed game"))
        XCTAssertTrue(guide.contains("place_mission_order"))
        XCTAssertTrue(guide.contains("never claim the order was placed until"))
        XCTAssertTrue(guide.contains("shorter Rainbow"))
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
        XCTAssertTrue(realtime.contains("Rainbow Macaron Smoothie"))
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
        XCTAssertTrue(realtime.contains("Sociable, expressive, and curious"))
    }

    func test_realtimeGuide_opensWithoutForcingAnOrderFlow() {
        let guide = RealtimeConversationGuide().instructions(
            persona: persona,
            climate: SocialClimate()
        )

        let opening = RealtimeConversationGuide.openingInstructions(
            memory: ConversationMemory(),
            isReturningEncounter: false
        )
        XCTAssertTrue(opening.contains("Greet the visitor briefly and naturally"))
        XCTAssertTrue(opening.contains("must not force the visitor into an ordering flow"))
        XCTAssertFalse(opening.contains("direct them to use the kiosk"))
        XCTAssertTrue(guide.contains("Do not repeatedly steer the visitor"))
        XCTAssertTrue(guide.contains("when the visitor brings them up"))
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
        XCTAssertTrue(complete.contains("ORDER_PLACED=true"))
        XCTAssertTrue(complete.contains("DRINK_READY=false"))
        XCTAssertTrue(complete.contains("TERMINAL_RESPONSE=true"))
        XCTAssertTrue(complete.contains("vary the wording"))
        XCTAssertTrue(complete.contains("app will close the conversation"))
        XCTAssertTrue(complete.contains("let the visitor know when the drink is ready"))
        XCTAssertTrue(complete.contains("only drink preparation remains"))
        XCTAssertFalse(complete.contains("ORDER_COMPLETE=true"))
        XCTAssertFalse(askQuantity.contains("몇 잔이요?"))
        XCTAssertFalse(complete.contains("주문 완료됐습니다"))
    }

    func test_realtimeReadyOrder_requiresValidatedToolBeforeConfirmation() {
        let guide = RealtimeMissionRoutingDecision.missionOrderCandidate.promptGuide

        XCTAssertTrue(guide.contains("explicit evidence"))
        XCTAssertTrue(guide.contains("exactly one Rainbow Macaron Smoothie"))
        XCTAssertTrue(guide.contains("Call place_mission_order"))
        XCTAssertTrue(guide.contains("before the function result succeeds"))
    }

    func test_realtimeGuide_definesDistinctFreeConversationStyles() {
        let expectedRules: [(ClerkPersonality, String)] = [
            (.hurried, "Fast, practical, and slightly distracted"),
            (.chatty, "Sociable, expressive, and curious"),
            (.cautious, "Careful and reserved"),
            (.blunt, "Direct and terse"),
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
