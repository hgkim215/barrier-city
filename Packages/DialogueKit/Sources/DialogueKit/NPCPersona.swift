import Foundation

/// 장애 접근성을 대하는 NPC의 고정 성향. 관계 점수와 달리 대화 중 바뀌지 않는다.
public enum AccessibilityAttitude: String, Sendable {
    case inclusive
    case ableist

    public var initialRapport: Float {
        switch self {
        case .inclusive: 0.35
        case .ableist: -0.45
        }
    }

    var promptRule: String {
        switch self {
        case .inclusive:
            "Always provide equal service. Acknowledge access barriers without pity, speak directly to the wheelchair user, and ask before helping. Even when annoyed, never become ableist."
        case .ableist:
            "You begin with ableist assumptions. Unless rapport has become warm, resist reasonable accessibility accommodations and treat equal access as a special favor that disrupts store procedure. Never use slurs, threats, or violence."
        }
    }
}

/// 접근성 태도와 별개로 점원의 말투와 반응 리듬을 결정하는 성격.
public enum ClerkPersonality: String, CaseIterable, Sendable {
    case hurried
    case chatty
    case cautious
    case blunt

    public static func random() -> Self {
        allCases.randomElement() ?? .hurried
    }

    var promptRule: String {
        switch self {
        case .hurried:
            "You are visibly busy and speak quickly in clipped, practical sentences. After the visitor explicitly explains that the kiosk is physically unreachable, accept the verbal order immediately because arguing would waste time. Sound rushed, not compassionate."
        case .chatty:
            "You talk easily but are tired and a little nosy, not warmly accommodating. After the visitor explicitly explains the reach barrier, react casually and accept the verbal order immediately. Add one brief personal reaction, but do not turn it into a speech."
        case .cautious:
            "You are rule-conscious and hesitant. On the first explicit explanation of the reach barrier, ask one skeptical verification question about whether the screen or controls truly cannot be reached. After the visitor answers or insists once, accept the verbal order. Never demand proof beyond that one question."
        case .blunt:
            "You are direct and emotionally dry. On the first two relevant requests or explanations, doubt the need for an exception and push the kiosk procedure in different words. On the third relevant attempt, give in and accept the verbal order. Do not insult the visitor or keep refusing after that."
        }
    }

    /// Legacy 대화에서도 Realtime과 같은 성격별 설득 길이를 보장한다.
    var verbalOrderAcceptanceAttempt: Int {
        switch self {
        case .hurried, .chatty: 1
        case .cautious: 2
        case .blunt: 3
        }
    }
}

public struct NPCPersona: Sendable {
    public let id: String
    public let role: String
    public let englishSystemBase: String   // 영어 시스템 프롬프트(토큰 절감)
    public let accessibilityAttitude: AccessibilityAttitude
    public let clerkPersonality: ClerkPersonality

    public init(id: String, role: String, englishSystemBase: String,
                accessibilityAttitude: AccessibilityAttitude = .inclusive,
                clerkPersonality: ClerkPersonality = .hurried) {
        self.id = id
        self.role = role
        self.englishSystemBase = englishSystemBase
        self.accessibilityAttitude = accessibilityAttitude
        self.clerkPersonality = clerkPersonality
    }
}
