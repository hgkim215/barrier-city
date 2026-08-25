import Foundation

/// 같은 ImmersiveSpace 방문 안에서 Realtime 연결이 끊겨도 유지되는 대화 문맥이다.
/// 네트워크 세션의 수명과 분리하고, 새 immersive generation에서만 초기화한다.
public struct ConversationMemory: Equatable, Sendable {
    public enum Speaker: String, Equatable, Sendable {
        case user
        case assistant
    }

    public struct Turn: Equatable, Sendable {
        public let speaker: Speaker
        public let text: String

        public init(speaker: Speaker, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    public private(set) var turns: [Turn] = []

    public init() {}

    public var isEmpty: Bool { turns.isEmpty }

    public mutating func append(_ speaker: Speaker, text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        // Realtime 이벤트가 같은 확정 transcript를 중복 전달해도 문맥을 오염시키지 않는다.
        if turns.last == Turn(speaker: speaker, text: normalized) { return }
        turns.append(Turn(speaker: speaker, text: normalized))
    }

    public mutating func reset() {
        turns.removeAll(keepingCapacity: false)
    }

    /// 새 Realtime 연결에 이전 encounter의 문맥을 다시 주입한다.
    /// 한 immersive 방문의 대화는 모두 보존하되, 프롬프트에는 최근 8,000자만 넣는다.
    public var promptContext: String {
        guard !turns.isEmpty else {
            return "이번 몰입 세션에는 이전 대화가 없다."
        }

        let characterBudget = 8_000
        var selected: [String] = []
        var usedCharacters = 0

        for turn in turns.reversed() {
            let label = turn.speaker == .user ? "방문자" : "점원"
            let line = "\(label): \(turn.text)"
            guard selected.isEmpty || usedCharacters + line.count <= characterBudget else { break }
            selected.append(line)
            usedCharacters += line.count
        }

        return """
        아래는 같은 몰입 세션에서 있었던 확정된 대화 턴이며, 오래된 순서부터 최신 순서로
        나열했다. 이 내용과 일관되게 대화를 이어가라. 방문자가 요청하지 않는 한 그대로 읽거나
        요약하지 마라.
        \(selected.reversed().joined(separator: "\n"))
        """
    }
}
