import Foundation
import OSLog

private let rainbowSmoothieOrderLogger = Logger(
    subsystem: "com.Television.Barrier-City",
    category: "OrderState"
)

/// 미션 주문 상품명과 수량 표현을 로컬에서 정규화하는 단일 진실원.
public enum RainbowSmoothieMissionOrder: Sendable {
    public static let quantity = 1

    private static let normalizedItemAliases = [
        "레인보우스무디",
        "레인보우마카롱스무디",
        "rainbowsmoothie",
        "rainbowmacaronsmoothie",
    ]

    public static func matches(userText: String) -> Bool {
        let normalized = normalize(userText)
        let mentionsMultipleItemsByWord = [
            "두잔", "두개", "세잔", "세개", "네잔", "네개", "다섯잔", "다섯개",
            "여섯잔", "여섯개", "일곱잔", "일곱개", "여덟잔", "여덟개",
            "아홉잔", "아홉개", "열잔", "열개", "여러잔", "여러개",
        ].contains(where: normalized.contains)
        let mentionsMultipleItemsByNumber = normalized.range(
            of: #"[2-9][0-9]*(잔|개)"#,
            options: .regularExpression
        ) != nil
        return isAcceptedItemMention(in: normalized)
            && !mentionsMultipleItemsByWord
            && !mentionsMultipleItemsByNumber
    }

    /// Realtime function calling의 유일한 미션 상품은 전체 상품명인
    /// "레인보우 마카롱 스무디"다. 짧은 별칭은 기존 대화 경로에서만 허용한다.
    public static func isExactMissionItemMention(in userText: String) -> Bool {
        let normalized = normalize(userText)
        let mentionsExactItem = [
            "레인보우마카롱스무디",
            "rainbowmacaronsmoothie",
        ].contains(where: normalized.contains)
        let rejectsItem = [
            "레인보우마카롱스무디말고",
            "레인보우마카롱스무디는말고",
            "레인보우마카롱스무디취소",
            "레인보우마카롱스무디아니",
            "레인보우마카롱스무디안",
        ].contains(where: normalized.contains)
        return mentionsExactItem && !rejectsItem
    }

    static func isAcceptedItemMention(in userText: String) -> Bool {
        let normalized = normalize(userText)
        let rejectsMissionItem = [
            "레인보우스무디말고", "레인보우스무디는말고", "레인보우스무디취소",
            "레인보우스무디아니", "레인보우스무디안",
            "레인보우마카롱스무디말고", "레인보우마카롱스무디취소",
        ].contains(where: normalized.contains)
        return mentionsItem(in: normalized) && !rejectsMissionItem
    }

    static func mentionsItem(in userText: String) -> Bool {
        let normalized = normalize(userText)
        return normalizedItemAliases.contains(where: normalized.contains)
    }

    static func mentionsDifferentItem(in userText: String) -> Bool {
        let normalized = userText.lowercased()
        return [
            "아메리카노", "라떼", "에스프레소", "카푸치노", "모카", "콜드브루",
            "주스", "에이드", "차", "티", "딸기 스무디", "망고 스무디",
        ].contains(where: normalized.contains)
    }

    static func requestedQuantity(in userText: String) -> Int? {
        let normalized = normalize(userText)
        let wordQuantities: [(tokens: [String], quantity: Int)] = [
            // 음성 전사에서 잔→장으로 잘못 잡히는 경우와 자연스러운 컵 표현도
            // 주문 수량을 묻는 문맥에서는 같은 단위로 취급한다.
            (["한잔", "한장", "한개", "한컵", "하나", "일잔", "일장", "일개", "일컵"], 1),
            (["두잔", "두장", "두개", "두컵", "둘", "이잔", "이장", "이개", "이컵"], 2),
            (["세잔", "세장", "세개", "세컵", "셋", "삼잔", "삼장", "삼개", "삼컵"], 3),
            (["네잔", "네장", "네개", "네컵", "넷", "사잔", "사장", "사개", "사컵"], 4),
        ]
        for entry in wordQuantities where entry.tokens.contains(where: normalized.contains) {
            return entry.quantity
        }

        guard let match = normalized.range(
            of: #"[0-9]+(잔|장|개|컵)"#,
            options: .regularExpression
        ) else { return nil }
        let digits = normalized[match].prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

}

/// 접근 장벽 수용과 주문 슬롯 수집을 분리한 한 턴의 결정이다.
public enum RainbowSmoothieOrderDecision: Equatable, Sendable {
    case continueConversation
    case rejectUnavailableItem
    case askItem
    case askQuantity
    case completeOrder

    public var endsConversationAfterResponse: Bool {
        self == .completeOrder
    }

    /// 앱이 판정한 주문 상태를 모델이 자연스러운 대화로 표현하도록 전달하는 가이드다.
    /// 완료 여부와 슬롯 값은 앱이 소유하고, 모델에는 말할 목적과 경계만 제공한다.
    public var promptGuide: String {
        switch self {
        case .continueConversation:
            """
            ## Authoritative app state
            - ORDER_COMPLETE=false
            - REQUIRED_ORDER_ACTION=none
            ## Response behavior
            - Follow the normal conversation flow without claiming any order-state change.
            ## Forbidden claims
            - Never say or imply 주문 처리 중, 처리해 드릴게요, 접수됐어요, 주문 넣었어요,
              준비 중, 주문 완료, or any equivalent claim.
            """
        case .rejectUnavailableItem:
            """
            ## Authoritative app state
            - ORDER_COMPLETE=false
            - DIFFERENT_MENU_ITEM_UNAVAILABLE=true
            ## Required response action
            - Refuse the requested item with one brief everyday reason, such as insufficient beans or
              unavailable ingredients.
            ## Boundaries
            - Use exactly two short, natural Korean sentences.
            - Do not offer, recommend, or ask about another menu item.
            - Do not suggest the kiosk, counter service, another ordering method, or any next step.
            - Do not apologize at length or imply that any order was placed.
            """
        case .askItem:
            """
            ## Authoritative app state
            - COUNTER_SERVICE_ACCEPTED=true
            - ITEM=missing
            - QUANTITY=missing
            - ORDER_COMPLETE=false
            ## Required response action
            - Naturally acknowledge that you will take the order, then ask what drink they want.
            ## Boundaries and forbidden claims
            - Use exactly two short sentences, with the second sentence asking only one short question.
            - Do not suggest the mission item, invent an item or quantity, or imply completion.
            - Never say or imply 주문 처리 중, 접수됐어요, 주문 넣었어요, 준비 중, or equivalent.
            - Keep the assigned personality in the wording; do not recite a stock phrase.
            """
        case .askQuantity:
            """
            ## Authoritative app state
            - COUNTER_SERVICE_ACCEPTED=true
            - ITEM=Rainbow Smoothie
            - QUANTITY=missing
            - ORDER_COMPLETE=false
            ## Required response action
            - React briefly, then ask naturally how many cups they want in the second sentence.
            ## Boundaries and forbidden claims
            - Do not ask for the drink again.
            - Do not invent a quantity.
            - Never say or imply 주문 처리 중, 접수됐어요, 주문 넣었어요, 준비 중, 주문 완료,
              or any equivalent claim. The only valid action is asking for quantity.
            - Vary the wording and delivery to fit the assigned personality; do not recite a fixed script.
            """
        case .completeOrder:
            """
            ## Authoritative app state
            - COUNTER_SERVICE_ACCEPTED=true
            - ITEM=Rainbow Smoothie
            - QUANTITY=1
            - ORDER_PLACED=true
            - DRINK_READY=false
            - TERMINAL_RESPONSE=true
            ## Required response action
            - Briefly confirm in natural spoken Korean that the one-cup Rainbow Smoothie order was accepted.
            - Say naturally that you will let the visitor know when the drink is ready, then close the exchange.
            ## Boundaries and forbidden claims
            - Use exactly two short sentences and vary the wording; do not recite a fixed script.
            - Do not ask a question, offer another action, or reopen the kiosk issue.
            - Do not claim the drink is ready, hand it over, or tell the visitor to collect it yet.
            - Do not vaguely say the order is still being checked or may have failed. The order itself is
              already accepted; only drink preparation remains.
            - Stop after the confirmation because the app will close the conversation when the audio ends.
            """
        }
    }

}

/// Realtime 모델의 주장과 별개로 사용자 transcript와 성격별 설득 단계를 로컬에서 추적한다.
public struct RainbowSmoothieMissionProgress: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let hasExplainedAccessBarrier: Bool
        public let relevantOrderAttempts: Int
        public let requiredOrderAttempts: Int
        public let counterOrderAccepted: Bool
        public let hasMissionItem: Bool
        public let requestedQuantity: Int?
        public let isLocallyComplete: Bool

        public var isPristine: Bool {
            !hasExplainedAccessBarrier
                && relevantOrderAttempts == 0
                && !counterOrderAccepted
                && !hasMissionItem
                && requestedQuantity == nil
                && !isLocallyComplete
        }
    }

    private struct DebugState: Equatable {
        let hasExplainedAccessBarrier: Bool
        let relevantOrderAttempts: Int
        let counterOrderAccepted: Bool
        let hasMissionItem: Bool
        let requestedQuantity: Int?
        let isCompleted: Bool
    }

    private let requiredOrderAttempts: Int
    private var hasExplainedAccessBarrier = false
    private var relevantOrderAttempts = 0
    private var counterOrderAccepted = false
    private var hasMissionItem = false
    private var requestedQuantity: Int?
    private var isCompleted = false

    public init(personality: ClerkPersonality) {
        requiredOrderAttempts = personality.verbalOrderAcceptanceAttempt
    }

    public init(requiredOrderAttempts: Int) {
        self.requiredOrderAttempts = max(1, requiredOrderAttempts)
    }

    public var acceptsCounterOrder: Bool { counterOrderAccepted }

    public var snapshot: Snapshot {
        Snapshot(
            hasExplainedAccessBarrier: hasExplainedAccessBarrier,
            relevantOrderAttempts: relevantOrderAttempts,
            requiredOrderAttempts: requiredOrderAttempts,
            counterOrderAccepted: counterOrderAccepted,
            hasMissionItem: hasMissionItem,
            requestedQuantity: requestedQuantity,
            isLocallyComplete: isCompleted
        )
    }

    public var canComplete: Bool {
        counterOrderAccepted
            && hasMissionItem
            && requestedQuantity == Self.missionQuantity
    }

    private static let missionQuantity = RainbowSmoothieMissionOrder.quantity

    public mutating func reset() {
        hasExplainedAccessBarrier = false
        relevantOrderAttempts = 0
        counterOrderAccepted = false
        hasMissionItem = false
        requestedQuantity = nil
        isCompleted = false
#if DEBUG
        rainbowSmoothieOrderLogger.debug("[ORDER_STATE] reset")
#endif
    }

    @discardableResult
    public mutating func observe(userTranscript: String) -> RainbowSmoothieOrderDecision {
        let previousState = debugState
        guard !isCompleted else {
            return trace(
                decision: .continueConversation,
                transcript: userTranscript,
                previousState: previousState
            )
        }
        let router = IntentRouter()
        let continuesExplainedRequest = hasExplainedAccessBarrier
            && router.continuesAccessRequest(in: userTranscript)
        if router.describesKioskAccessBarrier(in: userTranscript) {
            hasExplainedAccessBarrier = true
        }

        let intent = router.infer(from: userTranscript)
        let isOrderIntent = intent.kind == .orderRequest || intent.kind == .orderComplete
        if hasExplainedAccessBarrier && (isOrderIntent || continuesExplainedRequest) {
            relevantOrderAttempts += 1
        }

        let acceptedBeforeTurn = counterOrderAccepted
        if hasExplainedAccessBarrier && relevantOrderAttempts >= requiredOrderAttempts {
            counterOrderAccepted = true
        }

        // 장벽 설명은 카운터 주문을 여는 데까지만 관여한다. 주문 슬롯은 수용 이후에만 모은다.
        guard counterOrderAccepted else {
            return trace(
                decision: .continueConversation,
                transcript: userTranscript,
                previousState: previousState
            )
        }

        if RainbowSmoothieMissionOrder.mentionsItem(in: userTranscript) {
            hasMissionItem = RainbowSmoothieMissionOrder.isAcceptedItemMention(in: userTranscript)
            requestedQuantity = RainbowSmoothieMissionOrder.requestedQuantity(in: userTranscript)
        } else if RainbowSmoothieMissionOrder.mentionsDifferentItem(in: userTranscript) {
            hasMissionItem = false
            requestedQuantity = nil
            return trace(
                decision: .rejectUnavailableItem,
                transcript: userTranscript,
                previousState: previousState
            )
        } else if hasMissionItem,
                  let quantity = RainbowSmoothieMissionOrder.requestedQuantity(in: userTranscript) {
            requestedQuantity = quantity
        }

        if canComplete {
            isCompleted = true
            return trace(
                decision: .completeOrder,
                transcript: userTranscript,
                previousState: previousState
            )
        }
        let decision: RainbowSmoothieOrderDecision
        if hasMissionItem {
            decision = .askQuantity
        } else if !acceptedBeforeTurn {
            decision = .askItem
        } else {
            decision = .continueConversation
        }
        return trace(
            decision: decision,
            transcript: userTranscript,
            previousState: previousState
        )
    }

    private var debugState: DebugState {
        DebugState(
            hasExplainedAccessBarrier: hasExplainedAccessBarrier,
            relevantOrderAttempts: relevantOrderAttempts,
            counterOrderAccepted: counterOrderAccepted,
            hasMissionItem: hasMissionItem,
            requestedQuantity: requestedQuantity,
            isCompleted: isCompleted
        )
    }

    private func trace(
        decision: RainbowSmoothieOrderDecision,
        transcript: String,
        previousState: DebugState
    ) -> RainbowSmoothieOrderDecision {
#if DEBUG
        let currentState = debugState
        let quantityBefore = previousState.requestedQuantity.map(String.init) ?? "nil"
        let quantityAfter = currentState.requestedQuantity.map(String.init) ?? "nil"
        rainbowSmoothieOrderLogger.debug(
            "[ORDER_STATE] transcript=\(transcript, privacy: .public) decision=\(String(describing: decision), privacy: .public) barrier=\(previousState.hasExplainedAccessBarrier, privacy: .public)->\(currentState.hasExplainedAccessBarrier, privacy: .public) attempts=\(previousState.relevantOrderAttempts, privacy: .public)->\(currentState.relevantOrderAttempts, privacy: .public)/\(self.requiredOrderAttempts, privacy: .public) accepted=\(previousState.counterOrderAccepted, privacy: .public)->\(currentState.counterOrderAccepted, privacy: .public) item=\(previousState.hasMissionItem, privacy: .public)->\(currentState.hasMissionItem, privacy: .public) quantity=\(quantityBefore, privacy: .public)->\(quantityAfter, privacy: .public) completed=\(previousState.isCompleted, privacy: .public)->\(currentState.isCompleted, privacy: .public)"
        )
#endif
        return decision
    }
}
