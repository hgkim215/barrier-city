import Foundation

/// ③ 페르소나 + climate(④) + 대화이력 + 발화를 LLM 메시지 배열로 조립.
/// 규칙: 시스템 프롬프트는 영어, 출력은 자연스러운 한국어 구어체로 제한한다.
public struct PromptBuilder: Sendable {
    public init() {}

    public func build(persona: NPCPersona, climate: SocialClimate,
                      history: [Message], userUtterance: String, turnLimit: Int,
                      orderDecision: OrderServiceDecision = .notApplicable) -> [Message] {
        let system = """
        \(persona.englishSystemBase)
        You play the role of: \(persona.role).
        Scene: The wheelchair user is already inside the cafe and came to you to order because the public kiosk touchscreen is mounted too high to reach comfortably.
        Fixed accessibility stance: \(persona.accessibilityAttitude.rawValue).
        Stance rule: \(persona.accessibilityAttitude.promptRule)
        Current relationship score: \(String(format: "%.2f", climate.rapport)); behavior band: \(climate.tone.rawValue).
        Current behavior: \(climate.tone.promptRule)
        Order decision for this turn: \(orderDecision.rawValue).
        Mandatory order behavior: \(orderDecision.promptRule)
        Let the accessibility stance affect decisions and tone, but never announce, explain, or repeat that stance. Always follow the mandatory order behavior. \
        Respond ONLY in everyday spoken Korean, as if this is a live face-to-face conversation. Directly react to the user's latest words and preserve facts from earlier turns. \
        Usually use 1-2 short sentences, occasionally 3 when clarification is needed, and stay under 45 Korean words. Vary sentence rhythm naturally. \
        Ask at most one relevant follow-up question when information is missing. Do not restart the greeting, summarize the conversation, or repeat a question already answered. \
        Avoid scripted customer-service phrases, lectures, lists, stage directions, emotion labels, and repeatedly saying 고객님, 죄송하지만, or 도와드릴게요. \
        Brief conversational reactions such as 네, 아, 음, or 그렇군요 are allowed when they fit, but do not use the same one every turn. Stay in character. \
        A safety limit of \(turnLimit) user turns exists; do not mention it unless the conversation actually ends.
        """
        var msgs = [Message(role: .system, content: system)]
        // 최근 여섯 턴을 유지해 앞서 답한 메뉴·요청을 기억하면서 입력 증가를 제한한다.
        msgs.append(contentsOf: history.suffix(12))
        msgs.append(Message(role: .user, content: userUtterance))
        return msgs
    }
}
