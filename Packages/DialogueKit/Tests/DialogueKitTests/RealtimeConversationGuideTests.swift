import XCTest
@testable import DialogueKit

final class RealtimeConversationGuideTests: XCTestCase {
    private let persona = NPCPersona(
        id: "staff",
        role: "cafe staff",
        englishSystemBase: "You are a busy cafe staff member."
    )

    func test_prioritizesNaturalConversationOverScripts() {
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
        XCTAssertTrue(guide.contains("at least two complete sentences"))
    }

    func test_keepsOnlyMissionOrderDeterministic() {
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
        XCTAssertTrue(guide.contains("Rainbow Macaron Smoothie"))
        XCTAssertTrue(guide.contains("레인보우 마카롱 스무디"))
    }

    func test_personalityIsExplicitInRealtimePrompt() {
        let chatty = NPCPersona(
            id: "staff",
            role: "cafe staff",
            englishSystemBase: "You are staff.",
            accessibilityAttitude: .ableist,
            clerkPersonality: .chatty
        )
        let realtime = RealtimeConversationGuide().instructions(
            persona: chatty,
            climate: SocialClimate()
        )

        XCTAssertTrue(realtime.contains("Clerk personality: chatty"))
        XCTAssertTrue(realtime.contains("Talkative but tired and a little nosy"))
    }

    func test_opensWithoutForcingAnOrderFlow() {
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
        XCTAssertTrue(opening.contains("exactly two short sentences"))
    }

    func test_readyOrder_requiresValidatedToolBeforeConfirmation() {
        let guide = RealtimeMissionRoutingDecision.missionOrderCandidate.promptGuide

        XCTAssertTrue(guide.contains("explicit evidence"))
        XCTAssertTrue(guide.contains("exactly one Rainbow Macaron Smoothie"))
        XCTAssertTrue(guide.contains("Call place_mission_order"))
        XCTAssertTrue(guide.contains("before the function result succeeds"))
    }

    func test_definesDistinctFreeConversationStyles() {
        let expectedRules: [(ClerkPersonality, String)] = [
            (.hurried, "Fast, clipped, visibly busy"),
            (.chatty, "Talkative but tired and a little nosy"),
            (.cautious, "Guarded, skeptical, and reluctant"),
            (.blunt, "Blunt, emotionally dry, and visibly impatient"),
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
}
