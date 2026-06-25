import Foundation

public struct PlayerTurn: Sendable {
    public let text: String
    public let polite: Bool
    public let impatient: Bool
    public init(text: String, polite: Bool, impatient: Bool) {
        self.text = text; self.polite = polite; self.impatient = impatient
    }
}

public enum Tone: String, Sendable { case warm, neutral, curt }

/// ④ AI#4: 플레이어 태도를 누적해 NPC 톤·행인 도움 확률을 좌우한다. 순수 로직(네트워크/UI 의존 없음).
public struct SocialClimate: Sendable {
    public var rapport: Float   // -1(적대) ~ +1(우호)
    public init(rapport: Float = 0) { self.rapport = rapport }

    public mutating func apply(_ turn: PlayerTurn) {
        rapport += turn.polite ? 0.15 : -0.2
        rapport -= turn.impatient ? 0.1 : 0
        rapport = max(-1, min(1, rapport))
    }

    public var tone: Tone {
        if rapport > 0.2 { return .warm }
        if rapport < -0.2 { return .curt }
        return .neutral
    }

    public var helpChance: Float { 0.3 + 0.5 * max(0, rapport) }
}
