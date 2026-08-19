import Foundation

/// 한 사용자 턴에 주문 도구를 노출할지 결정한다. 대화의 내용이나 말투는 결정하지 않는다.
public enum RealtimeMissionRoutingDecision: Equatable, Sendable {
    case ordinaryConversation
    case partialMissionOrder
    case missionOrderCandidate

    public var exposesMissionOrderTool: Bool {
        self == .missionOrderCandidate
    }

    public var promptGuide: String {
        switch self {
        case .ordinaryConversation:
            "Continue the conversation naturally. No function is available for this response."
        case .partialMissionOrder:
            "The visitor may be forming an order, but the exact mission item and one-cup quantity are not both established. Respond naturally and clarify only if it fits the conversation. No function is available for this response."
        case .missionOrderCandidate:
            "The app found explicit evidence that the visitor is ordering exactly one Rainbow Macaron Smoothie. Call place_mission_order with the canonical item and quantity. Do not announce placement before the function result succeeds."
        }
    }
}

/// Realtime tool 호출을 앱 미션 이벤트와 서버 응답으로 변환한다.
/// 자유 대화는 모델에 맡기고 정확한 미션 주문 증거만 로컬에서 누적·검증한다.
public struct RealtimeMissionCoordinator: Sendable {
    public struct OrderToolEvaluation: Equatable, Sendable {
        public enum Outcome: String, Equatable, Sendable {
            case agreement
            case missedProposal
            case prematureProposal
            case invalidProposal
        }

        public let outcome: Outcome
        public let localOrderReady: Bool
        public let modelProposedOrder: Bool
        public let argumentsValid: Bool?
    }

    public struct Snapshot: Equatable, Sendable {
        public let hasMissionItem: Bool
        public let requestedQuantity: Int?
        public let orderPlaced: Bool

        public var isPristine: Bool {
            !hasMissionItem && requestedQuantity == nil && !orderPlaced
        }

        public var promptGuide: String {
            let quantity = requestedQuantity.map(String.init) ?? "missing"
            return """
            # App-owned mission state
            - EXACT_ITEM=\(hasMissionItem ? "Rainbow Macaron Smoothie" : "missing")
            - QUANTITY=\(quantity)
            - ORDER_PLACED=\(orderPlaced)
            This state is authoritative only for the mission order. It must not constrain ordinary conversation.
            """
        }
    }

    public struct FunctionCall: Sendable {
        public let callID: String
        public let output: String
        public let followUpInstructions: String
    }

    private var hasMissionItem = false
    private var requestedQuantity: Int?
    private var isAwaitingMissionQuantity = false
    private var orderWasPlaced = false
    private var hasPendingOrderCompletion = false
    private var pendingFunctionCall: FunctionCall?
    private var localOrderReadyForCurrentTurn: Bool?
    private var orderToolWasProposed = false
    private var orderToolArgumentsWereValid: Bool?

    public init(personality _: ClerkPersonality = .hurried) {}

    public mutating func resetImmersiveProgress() {
        hasMissionItem = false
        requestedQuantity = nil
        isAwaitingMissionQuantity = false
        orderWasPlaced = false
        hasPendingOrderCompletion = false
        pendingFunctionCall = nil
        clearOrderToolEvaluation()
    }

    /// Realtime 연결만 끝날 때 호출한다. 확정된 주문 슬롯과 완료 이벤트는 같은
    /// ImmersiveSpace 방문 동안 보존한다.
    public mutating func clearEncounterTransientState() {
        pendingFunctionCall = nil
        clearOrderToolEvaluation()
    }

    public var snapshot: Snapshot {
        Snapshot(
            hasMissionItem: hasMissionItem,
            requestedQuantity: requestedQuantity,
            orderPlaced: orderWasPlaced
        )
    }

    @discardableResult
    public mutating func observe(
        userTranscript: String
    ) -> RealtimeMissionRoutingDecision {
        orderToolWasProposed = false
        orderToolArgumentsWereValid = nil

        guard !orderWasPlaced else {
            localOrderReadyForCurrentTurn = false
            return .ordinaryConversation
        }

        let transcript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactItemMentioned = RainbowSmoothieMissionOrder.isExactMissionItemMention(
            in: transcript
        )
        let quantity = RainbowSmoothieMissionOrder.requestedQuantity(in: transcript)
        let explicitOrderIntent = Self.expressesOrderIntent(transcript)
        let bareItemAnswer = exactItemMentioned && Self.looksLikeBareItemAnswer(transcript)

        if Self.cancelsMissionOrder(transcript)
            || (RainbowSmoothieMissionOrder.mentionsDifferentItem(in: transcript)
                && explicitOrderIntent) {
            hasMissionItem = false
            requestedQuantity = nil
            isAwaitingMissionQuantity = false
            localOrderReadyForCurrentTurn = false
            return .ordinaryConversation
        }

        if exactItemMentioned && (explicitOrderIntent || bareItemAnswer) {
            hasMissionItem = true
            requestedQuantity = quantity
            isAwaitingMissionQuantity = quantity == nil
        } else if isAwaitingMissionQuantity, let quantity {
            requestedQuantity = quantity
            isAwaitingMissionQuantity = false
        }

        let ready = hasMissionItem
            && requestedQuantity == RainbowSmoothieMissionOrder.quantity
            && (exactItemMentioned || quantity != nil)
        localOrderReadyForCurrentTurn = ready

        if ready { return .missionOrderCandidate }
        if hasMissionItem { return .partialMissionOrder }
        return .ordinaryConversation
    }

    /// 공개되는 유일한 함수다. 모델이 보낸 JSON과 로컬 transcript 증거가 모두 맞아야
    /// 실제 미션 완료 이벤트를 생성한다.
    public mutating func register(
        name: String,
        callID: String,
        arguments: String
    ) -> MissionEvent? {
        orderToolWasProposed = name == "place_mission_order"
        let argumentsAreValid = validateMissionOrderArguments(arguments)
        orderToolArgumentsWereValid = argumentsAreValid
        let locallyReady = hasMissionItem
            && requestedQuantity == RainbowSmoothieMissionOrder.quantity
        let accepted = name == "place_mission_order" && argumentsAreValid && locallyReady

        let output: String
        let followUpInstructions: String
        if accepted {
            if !orderWasPlaced {
                orderWasPlaced = true
                hasPendingOrderCompletion = true
            }
            output = #"{"success":true,"item":"rainbow_macaron_smoothie","quantity":1}"#
            followUpInstructions = """
              The app validated and placed exactly one Rainbow Macaron Smoothie order. Confirm it briefly
              in natural Korean and say the visitor will be notified when it is ready. Do not say the drink
              itself is already ready and do not mention functions or JSON.
              """
        } else {
            output = #"{"success":false,"message":"mission order validation failed"}"#
            followUpInstructions = """
              The app did not place an order. Continue naturally in Korean without exposing technical
              details or claiming success. Ask for the exact item or one-cup quantity only if needed.
              """
        }

        pendingFunctionCall = FunctionCall(
            callID: callID,
            output: output,
            followUpInstructions: followUpInstructions
        )
        return nil
    }

    public mutating func finishOrderToolEvaluation() -> OrderToolEvaluation? {
        guard let localOrderReady = localOrderReadyForCurrentTurn else { return nil }
        let outcome: OrderToolEvaluation.Outcome
        if localOrderReady {
            if !orderToolWasProposed {
                outcome = .missedProposal
            } else if orderToolArgumentsWereValid == true {
                outcome = .agreement
            } else {
                outcome = .invalidProposal
            }
        } else {
            outcome = orderToolWasProposed ? .prematureProposal : .agreement
        }
        let evaluation = OrderToolEvaluation(
            outcome: outcome,
            localOrderReady: localOrderReady,
            modelProposedOrder: orderToolWasProposed,
            argumentsValid: orderToolArgumentsWereValid
        )
        clearOrderToolEvaluation()
        return evaluation
    }

    public mutating func takeFunctionCall() -> FunctionCall? {
        defer { pendingFunctionCall = nil }
        return pendingFunctionCall
    }

    public mutating func takeCompletedEvent() -> MissionEvent? {
        guard hasPendingOrderCompletion else { return nil }
        hasPendingOrderCompletion = false
        return .orderPlaced
    }

    private func validateMissionOrderArguments(_ arguments: String) -> Bool {
        struct Arguments: Decodable {
            let item: String
            let quantity: Int
        }
        guard let data = arguments.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Arguments.self, from: data) else {
            return false
        }
        return decoded.item == "rainbow_macaron_smoothie"
            && decoded.quantity == RainbowSmoothieMissionOrder.quantity
    }

    private static func expressesOrderIntent(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return [
            "주세요", "줘요", "줘", "주문", "시킬게", "시켜", "부탁", "할게요",
            "할게", "먹을게", "마실게", "한 잔이요", "한잔이요",
        ].contains(where: lowered.contains)
    }

    private static func looksLikeBareItemAnswer(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let questionSignals = ["?", "？", "맛", "얼마", "있나요", "있어요?", "추천", "어때"]
        return text.count <= 40 && !questionSignals.contains(where: lowered.contains)
    }

    private static func cancelsMissionOrder(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return [
            "레인보우마카롱스무디취소",
            "레인보우마카롱스무디말고",
            "레인보우마카롱스무디아니",
            "레인보우마카롱스무디안먹",
            "레인보우마카롱스무디안마실",
        ].contains(where: normalized.contains)
    }

    private mutating func clearOrderToolEvaluation() {
        localOrderReadyForCurrentTurn = nil
        orderToolWasProposed = false
        orderToolArgumentsWereValid = nil
    }
}
