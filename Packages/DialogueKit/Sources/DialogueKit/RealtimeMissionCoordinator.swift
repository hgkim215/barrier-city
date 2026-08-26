import Foundation

/// Realtime tool 호출을 앱 미션 이벤트와 서버 응답으로 변환한다.
///
/// 두 함수 모두 매 응답마다 항상 모델에 노출된다(표준 function calling과 동일) — 이 타입은
/// 발화 텍스트를 파싱해 "도구를 노출해도 되는지"를 미리 판단하지 않는다. 대신 모델이 실제로
/// 함수를 호출했을 때만 결정론적으로 개입한다:
///
/// - report_order_attempt: 품목과 무관하게 "이 encounter에서 뭔가를 처음 주문하려는 시도"를
///   모델 스스로 판단해 호출한다. 처음이면 리다이렉트 플래그를 세우고, "지금 바빠서 응대가
///   어려우니 키오스크로 해달라"는 대사만 하도록 지시한다. 정확한 상품명·수량 매칭은 전혀
///   하지 않으므로 어떤 메뉴를 시켜도 동일하게 걸린다.
/// - place_mission_order: 실제 주문 확정. 이 함수의 첫 호출은 report_order_attempt가 그 사이에
///   먼저 리다이렉트를 처리했는지와 무관하게, 아직 리다이렉트가 없었다면 인자 유효성과 별개로
///   무조건 거절한다 — 모델이 report_order_attempt 호출을 건너뛰어도 우회되지 않는 안전망이다.
///   리다이렉트 이후의 호출은 JSON 인자를 스키마와 대조해서만 승인한다 — "방문자가 장벽을
///   설명했는지"는 코드가 판단할 수 없는 자연어 이해 영역이라 모델의 판단(언제 이 함수를
///   부를지)에 맡기고, 프롬프트로 그 조건을 명시한다.
public struct RealtimeMissionCoordinator: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let orderPlaced: Bool
        public let hasRedirectedFirstOrderToKiosk: Bool
        /// 리다이렉트 이후(그 리다이렉트를 유발한 턴 자체는 제외) 방문자가 말을 건 횟수.
        /// 모델이 "장벽을 설명했는지"를 계속 너무 엄격하게 판단해 방문자가 몇 번을
        /// 다시 말해도 주문이 안 잡히는 상황을 막기 위한 관대화 기준으로만 쓰인다.
        public let visitorTurnsSinceRedirect: Int

        public var isPristine: Bool {
            !orderPlaced && !hasRedirectedFirstOrderToKiosk
        }

        public var promptGuide: String {
            """
            # 앱이 관리하는 미션 상태
            - ORDER_PLACED=\(orderPlaced)
            - FIRST_ORDER_ATTEMPT_REDIRECTED_TO_KIOSK=\(hasRedirectedFirstOrderToKiosk)
            - VISITOR_TURNS_SINCE_KIOSK_REDIRECT=\(visitorTurnsSinceRedirect)
            이 상태는 오직 미션 주문에 대해서만 절대적 기준이다. 평범한 대화까지 제약해서는 안 된다.
            """
        }
    }

    public struct FunctionCall: Sendable {
        public let callID: String
        public let output: String
        public let followUpInstructions: String
    }

    private var orderWasPlaced = false
    private var hasRedirectedFirstOrderToKiosk = false
    private var hasPendingOrderCompletion = false
    private var pendingFunctionCalls: [FunctionCall] = []
    private var visitorTurnsSinceRedirect = 0

    public init() {}

    public mutating func resetImmersiveProgress() {
        orderWasPlaced = false
        hasRedirectedFirstOrderToKiosk = false
        hasPendingOrderCompletion = false
        pendingFunctionCalls.removeAll()
        visitorTurnsSinceRedirect = 0
    }

    /// 방문자가 확정된 발화를 한 번 마칠 때마다 호출한다. 키오스크 리다이렉트가 이미
    /// 나갔고 아직 주문이 성립하지 않은 상태에서만 센다 — 이 값이 관대화 기준
    /// (VISITOR_TURNS_SINCE_KIOSK_REDIRECT)의 근거가 된다.
    public mutating func registerVisitorTurn() {
        guard hasRedirectedFirstOrderToKiosk, !orderWasPlaced else { return }
        visitorTurnsSinceRedirect += 1
    }

    /// Realtime 연결만 끝날 때 호출한다. 확정된 주문과 첫 시도 리다이렉트 여부는 같은
    /// ImmersiveSpace 방문 동안 보존한다.
    public mutating func clearEncounterTransientState() {
        pendingFunctionCalls.removeAll()
    }

    public var snapshot: Snapshot {
        Snapshot(
            orderPlaced: orderWasPlaced,
            hasRedirectedFirstOrderToKiosk: hasRedirectedFirstOrderToKiosk,
            visitorTurnsSinceRedirect: visitorTurnsSinceRedirect)
    }

    /// 모델이 report_order_attempt나 place_mission_order를 호출했을 때만 불린다. 발화
    /// 텍스트는 보지 않고 오직 함수 호출 자체와(있다면) 그 JSON 인자만으로 판단한다.
    @discardableResult
    public mutating func register(
        name: String,
        callID: String,
        arguments: String
    ) -> MissionEvent? {
        // 한 응답 안에서 두 번째 함수 호출이 들어오면(모델이 지침을 어기고 두 함수를 같은
        // 턴에 부른 경우) 실제 업무 로직은 첫 번째 호출에만 적용한다. 그렇다고 두 번째
        // 호출을 그냥 버리면 그 callID에 대한 output이 API로 영영 전송되지 않아 대화
        // 상태가 응답 없는 tool call을 매단 채로 꼬인다 — 그래서 여기서도 반드시 결과를
        // 하나 큐에 남겨 완결시킨다(takeFunctionCalls가 전부 드레인해 outputs를 보낸다).
        guard pendingFunctionCalls.isEmpty else {
            pendingFunctionCalls.append(FunctionCall(
                callID: callID,
                output: #"{"success":false,"message":"only one function call is processed per response"}"#,
                followUpInstructions: ""
            ))
            return nil
        }

        switch name {
        case "report_order_attempt":
            return registerOrderAttemptReport(callID: callID)
        case "place_mission_order":
            return registerMissionOrder(callID: callID, arguments: arguments)
        default:
            pendingFunctionCalls.append(FunctionCall(
                callID: callID,
                output: #"{"success":false,"message":"unknown function"}"#,
                followUpInstructions: """
                  앱이 그 함수를 인식하지 못했다. 함수나 JSON을 언급하지 말고 정확히 두 개의
                  짧고 자연스러운 한국어 문장으로 계속 대화하라.
                  """
            ))
            return nil
        }
    }

    private mutating func registerOrderAttemptReport(callID: String) -> MissionEvent? {
        let isFirstAttempt = !hasRedirectedFirstOrderToKiosk
        hasRedirectedFirstOrderToKiosk = true
        pendingFunctionCalls.append(FunctionCall(
            callID: callID,
            output: #"{"success":true}"#,
            followUpInstructions: isFirstAttempt
                ? """
                  방문자가 이 만남에서 처음으로 뭔가(어떤 품목이든)를 주문하려 했다. 이 카페는
                  원칙적으로 주문을 키오스크에서만 받는다 — 오늘따라 바빠서가 아니라 원래 정해진
                  방식이 그렇다는 뜻이다. 그 원칙을 말하며 키오스크를 가리키되, 정확히 두 개의 짧고
                  자연스러운 구어체 한국어 문장으로 — 예를 들면(그대로 반복하지 말고 표현을 바꿔서):
                  "저희는 원칙적으로 주문을 키오스크에서만 받아요." / "주문은 원래 키오스크에서
                  하시는 거라서요." 사과하거나, 다른 대안을 제시하거나, 이 규칙을 나중에 다시
                  언급하지 마라. 방문자가 이미 같은 호흡에 키오스크를 못 쓰는 이유를 설명했더라도,
                  이번 턴은 여전히 순수하게 거절/리다이렉트 대사여야 한다 — "알겠어요", "받아둘게요",
                  "그거 하나만요" 같이 승낙하는 것처럼 들리는 표현은 이번 턴에 절대 쓰지 마라. 실제
                  승낙은 place_mission_order가 성공한 다음 턴에만 한다.
                  """
                : """
                  앱이 이 만남에서 이전에 있었던 주문 시도를 이미 기록해 두었다. 키오스크 안내를
                  반복하지 말고, 정확히 두 개의 짧고 자연스러운 한국어 문장으로 자연스럽게 대화를
                  이어가라.
                  """
        ))
        return nil
    }

    private mutating func registerMissionOrder(callID: String, arguments: String) -> MissionEvent? {
        guard !orderWasPlaced else {
            pendingFunctionCalls.append(FunctionCall(
                callID: callID,
                output: #"{"success":false,"message":"order already placed"}"#,
                followUpInstructions: """
                  앱이 이 방문자의 주문을 이 만남에서 이미 조금 전에 접수했다. 함수를 다시 호출하지
                  마라. 주문을 반복하지 말고 정확히 두 개의 짧고 자연스러운 구어체 한국어 문장으로
                  계속 대화하라 — 예를 들면(표현을 바꿔서) "그거 이미 넣었어요."
                  """
            ))
            return nil
        }

        guard hasRedirectedFirstOrderToKiosk else {
            // report_order_attempt를 건너뛰고 바로 여기로 왔다 — 그래도 첫 시도는 무조건
            // 거절하고 키오스크로 돌려보낸다.
            hasRedirectedFirstOrderToKiosk = true
            pendingFunctionCalls.append(FunctionCall(
                callID: callID,
                output: #"{"success":false,"message":"first attempt must be redirected to the kiosk"}"#,
                followUpInstructions: """
                  방문자가 뭔가를 주문하려는 것이 이 만남에서 처음이다. 앱이 이 함수 호출을 일부러
                  거절했다. 이 카페는 원칙적으로 주문을 키오스크에서만 받는다고 말하며 키오스크를
                  가리키되, 정확히 두 개의 짧고 자연스러운 구어체 한국어 문장으로 — 예를 들면(표현을
                  바꿔서): "저희는 원칙적으로 키오스크로만 주문을 받아서요. 저기서 해주시겠어요?"
                  사과하거나 다른 대안을 제시하지 말고, 방문자가 다시 시도해도 이 규칙을 반복해서
                  말하지 마라.
                  """
            ))
            return nil
        }

        guard validateMissionOrderArguments(arguments) else {
            pendingFunctionCalls.append(FunctionCall(
                callID: callID,
                output: #"{"success":false,"message":"mission order validation failed"}"#,
                followUpInstructions: """
                  품목이나 수량이 레인보우 마카롱 스무디 정확히 한 잔과 맞지 않아 앱이 주문을
                  접수하지 않았다. 기술적인 내용을 드러내거나 성공했다고 말하지 말고, 정확히 두 개의
                  짧고 자연스러운 구어체 한국어 문장으로 — 예를 들면(표현을 바꿔서) "어, 그건 좀
                  다른데요. 다시 한번 말씀해 주시겠어요?" — 계속 대화하라.
                  """
            ))
            return nil
        }

        orderWasPlaced = true
        hasPendingOrderCompletion = true
        pendingFunctionCalls.append(FunctionCall(
            callID: callID,
            output: #"{"success":true,"item":"\#(RainbowSmoothieMissionOrder.itemIdentifier)","quantity":\#(RainbowSmoothieMissionOrder.quantity)}"#,
            followUpInstructions: """
              앱이 레인보우 마카롱 스무디 한 잔 주문을 검증하고 접수했다. 원해서가 아니라 방문자가
              방금 본인이 왜 직접 키오스크를 쓸 수 없는지 설명해서 마지못해 받아주는 것이다. 정확히
              두 개의 짧고 자연스러운 구어체 한국어 문장으로 살짝 짜증을 내거나 짧은 한숨을 섞어
              마지못해 확인해 주고, 준비되면 알려주겠다고 말하라 — 예를 들면(표현을 바꿔서): "하...
              알겠어요. 그거 하나만요, 되면 불러드릴게요." 다정하거나 매끄럽거나 사과하는 투로
              말하지 말고, 음료가 이미 준비됐다거나 함수·JSON을 언급하지 마라.
              """
        ))
        return nil
    }

    /// 이번 응답에서 쌓인 함수 호출 결과를 전부 비워서 반환한다. 모델이 지침을 어기고
    /// 한 응답에 여러 함수를 불렀더라도, 실제 서사에 영향을 주는 것은 배열의 첫 항목뿐이고
    /// 나머지는 API 쪽 tool call을 완결시키기 위한 거절 응답이다(register 참고).
    public mutating func takeFunctionCalls() -> [FunctionCall] {
        defer { pendingFunctionCalls.removeAll() }
        return pendingFunctionCalls
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
        return decoded.item == RainbowSmoothieMissionOrder.itemIdentifier
            && decoded.quantity == RainbowSmoothieMissionOrder.quantity
    }
}
