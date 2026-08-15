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
    private var orderProgress: RainbowSmoothieMissionProgress

    public init(persona: NPCPersona, climate: SocialClimate? = nil, llm: LLMClient,
                guardian: SafetyGuard, cache: DialogueCache, turnLimit: Int,
                forcedOrderAcceptanceAttempt: Int? = nil) {
        self.persona = persona
        self.climate = climate ?? SocialClimate(rapport: persona.accessibilityAttitude.initialRapport)
        self.llm = llm
        self.guardian = guardian; self.cache = cache; self.turnLimit = turnLimit
        let acceptanceAttempt = max(
            1,
            persona.accessibilityAttitude == .inclusive
                ? 1
                : (forcedOrderAcceptanceAttempt ?? persona.clerkPersonality.verbalOrderAcceptanceAttempt)
        )
        orderProgress = RainbowSmoothieMissionProgress(
            requiredOrderAttempts: acceptanceAttempt
        )
    }

    /// 거리 이탈 후 다시 만난 새 대화의 턴 제한만 초기화한다. 같은 점원의 카운터
    /// 주문 수용 여부와 수집한 주문 슬롯은 유지해 대화가 처음부터 되돌아가지 않는다.
    public func beginEncounter() {
        turnCount = 0
    }

    /// 응답 없는 만남도 다음 대화의 태도에 반영되도록 관계 상태에 감점을 누적한다.
    public func applyInactivityPenalty(_ amount: Float = 0.1) {
        climate.applyInactivityPenalty(amount)
    }

    /// 네트워크 응답 생성과 분리해 사용자 발화의 태도만 관계 상태에 반영한다.
    /// Realtime처럼 응답 생성을 다른 계층이 담당하는 경로에서도 같은 규칙을 재사용한다.
    @discardableResult
    public func observePlayerTurn(_ utterance: String) -> SocialClimate {
        climate.apply(Self.assessAttitude(utterance))
        return climate
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
        observePlayerTurn(utterance)
        turnCount += 1
        let intent = router.infer(from: utterance)
        let acceptedBeforeTurn = orderProgress.acceptsCounterOrder
        let orderCollectionDecision = orderProgress.observe(
            userTranscript: utterance
        )
        let orderDecision = orderServiceDecision(
            for: intent,
            utterance: utterance,
            acceptedBeforeTurn: acceptedBeforeTurn
        )
        let resolvedMissionEvent = missionEvent(
            for: intent,
            orderCollectionDecision: orderCollectionDecision
        )

        // 3) 프롬프트 조립(③)
        let messages = promptBuilder.build(persona: persona, climate: climate,
            history: history, userUtterance: utterance, turnLimit: turnLimit,
            orderDecision: orderDecision,
            orderCollectionDecision: orderCollectionDecision)

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
            if sentences.isEmpty {
                return fallback(
                    orderCollectionDecision.endsConversationAfterResponse ? .orderConfirm : .timeout,
                    event: resolvedMissionEvent
                )
            }
            return TurnResult(spokenSentences: sentences,
                              event: resolvedMissionEvent,
                              usedFallback: false)
        }
        if let tail = chunker.flush() {
            sentences.append(tail)
            onSentence(tail)
        }
        if sentences.isEmpty {
            return fallback(
                orderCollectionDecision.endsConversationAfterResponse ? .orderConfirm : .timeout,
                event: resolvedMissionEvent
            )
        }

        // 5) 의도는 제한된 게임 상태이므로 로컬에서 즉시 라우팅(⑥)
        return TurnResult(
            spokenSentences: sentences,
            event: resolvedMissionEvent,
            usedFallback: false
        )
    }

    private func orderServiceDecision(
        for intent: DialogueIntent,
        utterance: String,
        acceptedBeforeTurn: Bool
    ) -> OrderServiceDecision {
        let isOrderIntent = intent.kind == .orderRequest || intent.kind == .orderComplete
        let isRelevantAttempt = isOrderIntent || router.continuesAccessRequest(in: utterance)
        guard isRelevantAttempt else {
            return .notApplicable
        }
        if acceptedBeforeTurn { return .acceptDirectly }
        guard orderProgress.acceptsCounterOrder else { return .refuseKioskOnly }
        return persona.accessibilityAttitude == .inclusive
            ? .acceptDirectly
            : .acceptReluctantly
    }

    private func missionEvent(for intent: DialogueIntent,
                              orderCollectionDecision: RainbowSmoothieOrderDecision) -> MissionEvent? {
        if orderCollectionDecision == .completeOrder { return .orderPlaced }
        switch intent.kind {
        case .helpRequest: return .helpRequested
        case .leave: return .exited
        case .orderRequest, .orderComplete, .smalltalk, .unknown: return nil
        }
    }

    private func fallback(_ situation: Situation, event: MissionEvent? = nil) -> TurnResult {
        let line = cache.line(for: situation)
        return TurnResult(spokenSentences: line.map { [$0.text] } ?? [],
                          event: event, usedFallback: true)
    }

    /// 경량 태도 휴리스틱. 장애 장벽을 단호하게 지적하는 것은 공격성으로 보지 않는다.
    static func assessAttitude(_ text: String) -> PlayerTurn {
        let polite = ["요", "주세요", "감사", "죄송", "부탁"].contains { text.contains($0) }
        let impatient = ["빨리", "당장", "언제까지", "어휴", "답답"].contains { text.contains($0) }
        let hostile = ["야", "바보", "멍청", "꺼져", "닥쳐", "짜증나"].contains { text.contains($0) }
        return PlayerTurn(text: text, polite: polite, impatient: impatient, hostile: hostile)
    }
}
