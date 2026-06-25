import Foundation

/// ③ 페르소나 + climate(④) + 대화이력 + 발화를 LLM 메시지 배열로 조립.
/// 규칙: 시스템 프롬프트는 영어, 출력은 한국어 강제, 첫 문장 짧게, 턴 상한 명시.
public struct PromptBuilder: Sendable {
    public init() {}

    public func build(persona: NPCPersona, climate: SocialClimate,
                      history: [Message], userUtterance: String, turnLimit: Int) -> [Message] {
        let system = """
        \(persona.englishSystemBase)
        You play the role of: \(persona.role).
        Current rapport with the customer is \(String(format: "%.2f", climate.rapport)) \
        and your tone must be \(climate.tone.rawValue). \
        If tone is curt, be terse and businesslike; if warm, be friendly.
        Respond ONLY in Korean, in natural spoken style. \
        Keep the first sentence short. Stay in character. \
        The whole conversation is limited to \(turnLimit) turns; wrap up if near the limit.
        """
        var msgs = [Message(role: .system, content: system)]
        msgs.append(contentsOf: history)
        msgs.append(Message(role: .user, content: userUtterance))
        return msgs
    }
}
