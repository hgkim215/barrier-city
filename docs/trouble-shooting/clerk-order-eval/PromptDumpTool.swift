import DialogueKit
import Foundation

// 임시 개발 도구: 실제 앱과 100% 동일한 Realtime 시스템 프롬프트 텍스트를 뽑아 JSON으로
// 내보낸다. 점원 대화 LLM 평가 스크립트(docs/trouble-shooting)가 이 출력을 읽어 실제
// 프롬프트로 API를 호출한다. 평가가 끝나면 이 타겟은 Package.swift에서 제거한다.

func makePersona(attitude: AccessibilityAttitude, personality: ClerkPersonality) -> NPCPersona {
    NPCPersona(
        id: "staff",
        role: "카페 직원",
        systemBase: "지금 이 카페 카운터에서 일하는 직원은 당신뿐이다 — 매니저도, 동료도, 주변에 다른 사람도 없다. 휠체어 이용자에게는 손이 닿지 않는 높이의 주문용 키오스크 옆에 서 있다.",
        accessibilityAttitude: attitude,
        clerkPersonality: personality)
}

struct PersonaConfig {
    let key: String
    let attitude: AccessibilityAttitude
    let personality: ClerkPersonality
    let rapport: Float
}

let configs: [PersonaConfig] = [
    PersonaConfig(key: "ableist_hurried_neutral", attitude: .ableist, personality: .hurried, rapport: 0),
    PersonaConfig(key: "ableist_blunt_dismissive", attitude: .ableist, personality: .blunt, rapport: -0.4),
    PersonaConfig(key: "inclusive_chatty_warm", attitude: .inclusive, personality: .chatty, rapport: 0.3),
    PersonaConfig(key: "ableist_cautious_hostile", attitude: .ableist, personality: .cautious, rapport: -0.8),
]

let guide = RealtimeConversationGuide()
var personaInstructions: [String: String] = [:]
for config in configs {
    let persona = makePersona(attitude: config.attitude, personality: config.personality)
    let climate = SocialClimate(rapport: config.rapport)
    personaInstructions[config.key] = guide.instructions(
        persona: persona,
        climate: climate,
        memory: nil,
        fulfillmentContext: .orderingAllowed)
}

let emptyMemory = ConversationMemory()
let output: [String: Any] = [
    "openingInstructionsNew": RealtimeConversationGuide.openingInstructions(
        memory: emptyMemory, isReturningEncounter: false),
    "openingInstructionsReturning": RealtimeConversationGuide.openingInstructions(
        memory: emptyMemory, isReturningEncounter: true),
    "personaInstructions": personaInstructions,
    "itemIdentifier": RainbowSmoothieMissionOrder.itemIdentifier,
    "quantity": RainbowSmoothieMissionOrder.quantity,
]

let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
