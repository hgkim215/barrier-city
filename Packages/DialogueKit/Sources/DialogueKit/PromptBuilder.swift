import Foundation

/// ③ 페르소나 + climate(④) + 대화이력 + 발화를 LLM 메시지 배열로 조립.
/// 규칙: 시스템 프롬프트는 영어, 출력은 한국어 강제, 첫 문장 짧게, 턴 상한 명시.
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
        Make the accessibility stance noticeable in the first sentence, but always follow the mandatory order behavior. \
        Respond ONLY in natural spoken Korean. Use 1-2 short sentences and at most 30 Korean words. \
        Put the important reaction first. Stay in character. \
        The whole conversation is limited to \(turnLimit) turns; wrap up if near the limit.
        """
        var msgs = [Message(role: .system, content: system)]
        // 최근 네 턴만 유지해 멀티턴 입력 토큰과 지연이 계속 커지는 것을 막는다.
        msgs.append(contentsOf: history.suffix(8))
        msgs.append(Message(role: .user, content: userUtterance))
        return msgs
    }
}
