import XCTest
@testable import DialogueKit

final class RealtimeConversationGuideTests: XCTestCase {
    private let persona = NPCPersona(
        id: "staff",
        role: "카페 직원",
        systemBase: "당신은 바쁜 카페 직원이다."
    )

    func test_prioritizesNaturalConversationOverScripts() {
        let guide = RealtimeConversationGuide().instructions(
            persona: persona,
            climate: SocialClimate(rapport: 0.1)
        )

        XCTAssertTrue(guide.contains("자연스러운 일상 구어체 한국어"))
        XCTAssertTrue(guide.contains("대화 전체에서 사용하는 언어는 한국어뿐"))
        XCTAssertTrue(guide.contains("방문자의 가장 최근 말뜻에 직접 대답"))
        XCTAssertTrue(guide.contains("진짜 잡담"))
        XCTAssertTrue(guide.contains("화제 전환"))
        XCTAssertTrue(guide.contains("정해진 대본"))
        XCTAssertTrue(guide.contains("매 답변 후에는 멈추고"))
        XCTAssertTrue(guide.contains("원두가 떨어졌다거나"))
        XCTAssertTrue(guide.contains("문장을 최소 두 개 담아야"))
    }

    func test_keepsOnlyMissionOrderDeterministic() {
        let ableist = NPCPersona(
            id: "staff",
            role: "카페 직원",
            systemBase: "당신은 바쁘다.",
            accessibilityAttitude: .ableist
        )
        let guide = RealtimeConversationGuide().instructions(
            persona: ableist,
            climate: SocialClimate(rapport: ableist.accessibilityAttitude.initialRapport)
        )

        XCTAssertTrue(guide.contains("평범한 대화는 게임 상태를 절대 바꾸지 않으며"))
        XCTAssertTrue(guide.contains("함수와 연결된 유일한 게임 행동은"))
        XCTAssertTrue(guide.contains("place_mission_order"))
        XCTAssertTrue(guide.contains("절대 주문이 접수됐다고 말하지 말고"))
        XCTAssertTrue(guide.contains("줄여 부른 스무디"))
        XCTAssertTrue(guide.contains("레인보우 마카롱 스무디"))
    }

    func test_personalityIsExplicitInRealtimePrompt() {
        let chatty = NPCPersona(
            id: "staff",
            role: "카페 직원",
            systemBase: "당신은 직원이다.",
            accessibilityAttitude: .ableist,
            clerkPersonality: .chatty
        )
        let realtime = RealtimeConversationGuide().instructions(
            persona: chatty,
            climate: SocialClimate()
        )

        XCTAssertTrue(realtime.contains("점원 성격: chatty"))
        XCTAssertTrue(realtime.contains("말이 많지만 피곤하고 약간 참견하기 좋아한다"))
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

        XCTAssertTrue(opening.contains("방문자에게 짧고 자연스럽게 구어체 한국어로 인사하라"))
        XCTAssertTrue(opening.contains("방문자를 주문 흐름으로 몰아가거나"))
        XCTAssertFalse(opening.contains("키오스크"))
        XCTAssertTrue(guide.contains("반복해서 먼저 꺼내지 마라"))
        XCTAssertTrue(guide.contains("꺼낼 때만 다루어라"))
        XCTAssertTrue(opening.contains("정확히 두 개의 짧은 문장으로"))
    }

    func test_missionBoundary_enforcesKioskFirstAndNoAlternatives() {
        let guide = RealtimeConversationGuide().instructions(
            persona: persona,
            climate: SocialClimate()
        )

        XCTAssertTrue(guide.contains("하기 전이자 place_mission_order보다 먼저 report_order_attempt를 호출하라"))
        XCTAssertTrue(guide.contains("그 호출을 일부러 거절하고"))
        XCTAssertTrue(guide.contains("방문자를 키오스크로 돌려보내라고"))
        XCTAssertTrue(guide.contains("다른 메뉴를 제안하거나"))
        XCTAssertTrue(guide.contains("한 번 방문에 한 잔만 가능하다고"))
    }

    func test_missionBoundary_allowsLenientAcceptanceAfterRepeatedAttempts() {
        let guide = RealtimeConversationGuide().instructions(
            persona: persona,
            climate: SocialClimate()
        )

        XCTAssertTrue(guide.contains("첫 주문 시도와 같은 호흡으로"))
        XCTAssertTrue(guide.contains("VISITOR_TURNS_SINCE_KIOSK_REDIRECT가 2에 도달하면"))
    }

    func test_missionBoundary_forbidsHandingOffToAnotherEmployee() {
        let guide = RealtimeConversationGuide().instructions(
            persona: persona,
            climate: SocialClimate()
        )

        XCTAssertTrue(guide.contains("지금 근무 중인 직원은 당신뿐이다"))
        XCTAssertTrue(guide.contains("다른 직원을 불러오겠다거나 기다려 달라는 말은 절대 하지 말고"))
    }

    func test_definesDistinctFreeConversationStyles() {
        let expectedRules: [(ClerkPersonality, String)] = [
            (.hurried, "말이 빠르고 짧으며, 눈에 띄게 바쁘고"),
            (.chatty, "말이 많지만 피곤하고 약간 참견하기 좋아한다"),
            (.cautious, "경계심이 많고 의심이 많으며"),
            (.blunt, "직설적이고 감정 표현이 메마르며"),
        ]

        for (personality, expected) in expectedRules {
            let personalityPersona = NPCPersona(
                id: "staff",
                role: "카페 직원",
                systemBase: "당신은 직원이다.",
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

    func test_fulfillmentContext_isInjectedIntoRealtimeInstructions() {
        for (context, requiredFact) in [
            (RainbowSmoothieFulfillmentContext.orderingAllowed, "FULFILLMENT=orderingAllowed"),
            (.preparing, "FULFILLMENT=preparing"),
            (.readyAtCounter, "FULFILLMENT=readyAtCounter"),
            (.failed, "FULFILLMENT=failed"),
        ] {
            let guide = RealtimeConversationGuide().instructions(
                persona: persona,
                climate: SocialClimate(),
                fulfillmentContext: context
            )
            XCTAssertTrue(guide.contains(requiredFact), "Missing fact \(requiredFact)")
        }
    }
}
