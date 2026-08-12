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
            "You are visibly busy and speak quickly in clipped, practical sentences. You want to resolve the situation fast, but you still react to what the visitor actually says."
        case .chatty:
            "You are sociable and expressive. Add brief personal reactions and casual warmth, but stay focused and never turn the exchange into a monologue."
        case .cautious:
            "You are rule-conscious and hesitant. You pause before making exceptions, confirm uncertain details carefully, and sound uneasy rather than robotic."
        case .blunt:
            "You are direct and emotionally dry. Use plain, concise wording and let impatience show through sentence endings, without insults or needless cruelty."
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
