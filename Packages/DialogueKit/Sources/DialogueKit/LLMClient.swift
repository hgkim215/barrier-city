import Foundation

/// ⑤ LLM 스트리밍 이벤트.
public enum LLMEvent: Equatable, Sendable {
    case token(String)            // NPC 대사 조각
    case intentFragment(String)   // 의도 JSON 조각(tool call arguments)
    case done
}

/// OpenAI Chat Completions SSE 한 줄을 LLMEvent로 파싱. 알 수 없는/빈 줄은 nil.
public func parseSSELine(_ line: String) -> LLMEvent? {
    guard line.hasPrefix("data: ") else { return nil }
    let payload = String(line.dropFirst(6))
    if payload == "[DONE]" { return .done }
    guard let data = payload.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = obj["choices"] as? [[String: Any]],
          let delta = choices.first?["delta"] as? [String: Any] else { return nil }

    if let toolCalls = delta["tool_calls"] as? [[String: Any]],
       let fn = toolCalls.first?["function"] as? [String: Any],
       let args = fn["arguments"] as? String, !args.isEmpty {
        return .intentFragment(args)
    }
    if let content = delta["content"] as? String, !content.isEmpty {
        return .token(content)
    }
    return nil
}

/// ⑤ 대화 LLM 추상화. 실제 구현(프록시→OpenAI)은 앱/통합 레이어에서 제공.
public protocol LLMClient: Sendable {
    func stream(messages: [Message]) -> AsyncThrowingStream<LLMEvent, Error>
}
