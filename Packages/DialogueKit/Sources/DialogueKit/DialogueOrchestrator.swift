import Foundation

public struct TurnResult: Equatable, Sendable {
    public let spokenSentences: [String]
    public let event: MissionEvent?
    public let usedFallback: Bool
}

/// ② 한 대화 턴을 지휘하는 유일한 코디네이터. 모든 실패는 캔드 폴백으로 흡수(throw 금지).
public actor DialogueOrchestrator {
    private let persona: NPCPersona
    private(set) public var climate: SocialClimate
    private let llm: LLMClient
    private let guardian: SafetyGuard
    private let cache: DialogueCache
    private let promptBuilder = PromptBuilder()
    private let router = IntentRouter()
    private let turnLimit: Int
    private var turnCount = 0

    public init(persona: NPCPersona, climate: SocialClimate, llm: LLMClient,
                guardian: SafetyGuard, cache: DialogueCache, turnLimit: Int) {
        self.persona = persona; self.climate = climate; self.llm = llm
        self.guardian = guardian; self.cache = cache; self.turnLimit = turnLimit
    }

    public func handle(utterance: String, history: [Message]) async -> TurnResult {
        // 1) 입력 가드
        if case .block = guardian.screen(utterance) {
            return fallback(.blockedContent)
        }
        // 1b) 턴 상한 강제 — 상한 도달 시 대화를 마무리 캔드로 종료(⑧)
        guard guardian.allowTurn(count: turnCount) else {
            return fallback(.turnLimitReached)
        }
        // 2) 태도 추정(경량 휴리스틱) → climate 갱신(④)
        let turn = Self.assessAttitude(utterance)
        climate.apply(turn)
        turnCount += 1

        // 3) 프롬프트 조립(③)
        let messages = promptBuilder.build(persona: persona, climate: climate,
            history: history, userUtterance: utterance, turnLimit: turnLimit)

        // 4) LLM 스트림 → 문장 청크 + 의도 누적
        var chunker = SentenceChunker()
        var sentences: [String] = []
        var intentJSON = ""
        do {
            stream: for try await event in llm.stream(messages: messages) {
                switch event {
                case .token(let t):
                    if case .block = guardian.screen(t) { continue } // 출력 청크 1차 필터(⑧)
                    sentences.append(contentsOf: chunker.feed(t))
                case .intentFragment(let f): intentJSON += f
                case .done: break stream
                }
            }
        } catch {
            return fallback(.timeout)   // 네트워크/스트림 실패 → 캔드(throw 안 함)
        }
        if let tail = chunker.flush() { sentences.append(tail) }
        if sentences.isEmpty { return fallback(.timeout) }   // 빈 응답도 폴백

        // 5) 의도 라우팅(⑥)
        let event = intentJSON.isEmpty ? nil
            : router.route(DialogueIntent.decode(fromJSON: intentJSON))
        return TurnResult(spokenSentences: sentences, event: event, usedFallback: false)
    }

    private func fallback(_ situation: Situation) -> TurnResult {
        let line = cache.line(for: situation)
        return TurnResult(spokenSentences: line.map { [$0.text] } ?? [],
                          event: nil, usedFallback: true)
    }

    /// 경량 태도 휴리스틱(정중/조급). 정교화는 LLM 구조화 출력의 politeness로 보강 가능.
    static func assessAttitude(_ text: String) -> PlayerTurn {
        let polite = ["요", "주세요", "감사", "죄송", "부탁"].contains { text.contains($0) }
        let impatient = ["빨리", "좀", "야", "어휴"].contains { text.contains($0) }
        return PlayerTurn(text: text, polite: polite, impatient: impatient)
    }
}
