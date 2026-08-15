import Foundation

public enum IntentKind: String, Codable, Sendable {
    /// 주문 의사·키오스크 장벽만 밝힌 상태. 메뉴를 더 물어야 하므로 미션을 끝내지 않는다.
    case orderRequest
    /// 구체적인 음료를 말해 실제 주문을 확정할 수 있는 상태.
    case orderComplete
    case helpRequest, leave, smalltalk, unknown
}

/// ⑥ LLM 구조화 출력으로 받는 의도. 스키마 밖/깨진 값은 .unknown으로 안전 강등.
public struct DialogueIntent: Codable, Equatable, Sendable {
    public let kind: IntentKind
    public let politeness: Int?
    public init(kind: IntentKind, politeness: Int? = nil) {
        self.kind = kind; self.politeness = politeness
    }

    private struct Raw: Codable { let kind: String; let politeness: Int? }

    public static func decode(fromJSON json: String) -> DialogueIntent {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return DialogueIntent(kind: .unknown)
        }
        let kind = IntentKind(rawValue: raw.kind) ?? .unknown
        return DialogueIntent(kind: kind, politeness: raw.politeness)
    }
}
