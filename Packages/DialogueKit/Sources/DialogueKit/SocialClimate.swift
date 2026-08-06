import Foundation

public struct PlayerTurn: Sendable {
    public let text: String
    public let polite: Bool
    public let impatient: Bool
    public let hostile: Bool
    public init(text: String, polite: Bool, impatient: Bool, hostile: Bool = false) {
        self.text = text
        self.polite = polite
        self.impatient = impatient
        self.hostile = hostile
    }
}

public enum Tone: String, Sendable {
    case supportive, warm, neutral, dismissive, hostile

    var promptRule: String {
        switch self {
        case .supportive:
            "Be openly respectful: validate the barrier, apologize when appropriate, and offer one concrete action after asking consent."
        case .warm:
            "Be friendly and cooperative. Acknowledge the barrier and offer one practical next step."
        case .neutral:
            "Be procedural and emotionally distant. Give only the minimum necessary response."
        case .dismissive:
            "Be visibly dismissive. Never use apology words such as 죄송 or 미안. Minimize the access problem and mechanically repeat store procedure instead of accommodating the customer."
        case .hostile:
            "Be openly exclusionary and impatient. Prioritize store rules and convenience over equal service, without slurs, threats, or violence."
        }
    }
}

/// ④ AI#4: 플레이어 태도를 누적해 NPC 톤·행인 도움 확률을 좌우한다. 순수 로직(네트워크/UI 의존 없음).
public struct SocialClimate: Sendable {
    public var rapport: Float   // -1(적대) ~ +1(우호)
    public init(rapport: Float = 0) { self.rapport = rapport }

    public mutating func apply(_ turn: PlayerTurn) {
        // 정중하지 않다는 이유만으로 감점하지 않는다. 휠체어 사용자의 단호한
        // 자기주장을 무례함으로 오해하지 않고, 명시적 공격성만 크게 반영한다.
        if turn.polite { rapport += 0.15 }
        if turn.hostile {
            rapport -= 0.30
        } else if turn.impatient {
            rapport -= 0.08
        }
        rapport = max(-1, min(1, rapport))
    }

    public var tone: Tone {
        if rapport >= 0.55 { return .supportive }
        if rapport >= 0.2 { return .warm }
        if rapport <= -0.6 { return .hostile }
        if rapport <= -0.2 { return .dismissive }
        return .neutral
    }

    public var helpChance: Float { max(0.1, min(0.9, 0.5 + 0.4 * rapport)) }
}
