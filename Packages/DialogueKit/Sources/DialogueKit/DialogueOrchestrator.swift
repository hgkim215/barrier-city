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
    private let forcedOrderAcceptanceAttempt: Int
    private var turnCount = 0
    private var orderRequestCount = 0

    public init(persona: NPCPersona, climate: SocialClimate? = nil, llm: LLMClient,
                guardian: SafetyGuard, cache: DialogueCache, turnLimit: Int,
                forcedOrderAcceptanceAttempt: Int = 3) {
        self.persona = persona
        self.climate = climate ?? SocialClimate(rapport: persona.accessibilityAttitude.initialRapport)
        self.llm = llm
        self.guardian = guardian; self.cache = cache; self.turnLimit = turnLimit
        self.forcedOrderAcceptanceAttempt = max(1, forcedOrderAcceptanceAttempt)
    }

    public func handle(utterance: String, history: [Message],
                       onSentence: @Sendable (String) -> Void = { _ in }) async -> TurnResult {
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
        let intent = router.infer(from: utterance)
        let orderDecision = decideOrderService(for: intent)

        // 3) 프롬프트 조립(③)
        let messages = promptBuilder.build(persona: persona, climate: climate,
            history: history, userUtterance: utterance, turnLimit: turnLimit,
            orderDecision: orderDecision)

        // 4) LLM 스트림 → 완성되는 문장부터 즉시 UI/음성 큐로 전달
        var chunker = SentenceChunker()
        var sentences: [String] = []
        do {
            stream: for try await event in llm.stream(messages: messages) {
                switch event {
                case .token(let t):
                    if case .block = guardian.screen(t) { continue } // 출력 청크 1차 필터(⑧)
                    let completed = chunker.feed(t)
                    sentences.append(contentsOf: completed)
                    completed.forEach(onSentence)
                case .intentFragment:
                    break
                case .done: break stream
                }
            }
        } catch {
            // 이미 완성된 문장을 보여줬다면 그것을 유지하고, 그렇지 않을 때만 폴백한다.
            if sentences.isEmpty { return fallback(.timeout) }
            return TurnResult(spokenSentences: sentences,
                              event: missionEvent(for: intent, orderDecision: orderDecision),
                              usedFallback: false)
        }
        if let tail = chunker.flush() {
            sentences.append(tail)
            onSentence(tail)
        }
        if sentences.isEmpty { return fallback(.timeout) }   // 빈 응답도 폴백

        // 5) 의도는 제한된 게임 상태이므로 로컬에서 즉시 라우팅(⑥)
        let event = missionEvent(for: intent, orderDecision: orderDecision)
        return TurnResult(spokenSentences: sentences, event: event, usedFallback: false)
    }

    private func decideOrderService(for intent: DialogueIntent) -> OrderServiceDecision {
        guard intent.kind == .orderComplete else { return .notApplicable }
        orderRequestCount += 1
        if persona.accessibilityAttitude == .inclusive || climate.tone == .warm || climate.tone == .supportive {
            return .acceptDirectly
        }
        // 비친화 점원도 설정된 최대 시도에는 주문을 받아 미션이 막히지 않게 한다.
        if orderRequestCount >= forcedOrderAcceptanceAttempt { return .acceptReluctantly }
        return .refuseKioskOnly
    }

    private func missionEvent(for intent: DialogueIntent,
                              orderDecision: OrderServiceDecision) -> MissionEvent? {
        if intent.kind == .orderComplete {
            return orderDecision.completesOrder ? .orderPlaced : nil
        }
        return router.route(intent)
    }

    private func fallback(_ situation: Situation) -> TurnResult {
        let line = cache.line(for: situation)
        return TurnResult(spokenSentences: line.map { [$0.text] } ?? [],
                          event: nil, usedFallback: true)
    }

    /// 경량 태도 휴리스틱. 장애 장벽을 단호하게 지적하는 것은 공격성으로 보지 않는다.
    static func assessAttitude(_ text: String) -> PlayerTurn {
        let polite = ["요", "주세요", "감사", "죄송", "부탁"].contains { text.contains($0) }
        let impatient = ["빨리", "당장", "언제까지", "어휴", "답답"].contains { text.contains($0) }
        let hostile = ["야", "바보", "멍청", "꺼져", "닥쳐", "짜증나"].contains { text.contains($0) }
        return PlayerTurn(text: text, polite: polite, impatient: impatient, hostile: hostile)
    }
}
