import Foundation
import DialogueKit

/// ⑤ LLMClient의 구체 구현. 프록시 /chat으로 stream:true + 의도용 tool을 보내고,
/// 응답 SSE 줄을 DialogueKit의 parseSSELine으로 LLMEvent로 변환해 방출한다.
/// 키는 모른다(프록시 뒤). 네트워크 실패는 스트림 throw로 전달 → Orchestrator가 폴백.
public struct OpenAILLMClient: LLMClient {
    let config: ProxyConfig
    let session: URLSession

    public init(config: ProxyConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func stream(messages: [Message]) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: config.chatURL)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try Self.body(messages: messages)
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    for try await line in bytes.lines {
                        if let ev = parseSSELine(line) {
                            continuation.yield(ev)
                            if case .done = ev { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 대화 + 의도(tool) 요청 바디. 시스템 프롬프트는 PromptBuilder가 영어로 구성해 messages로 들어온다.
    static func body(messages: [Message]) throws -> Data {
        let msgs = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "set_intent",
                "description": "Classify the player's turn intent and politeness.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string",
                                 "enum": ["orderComplete", "helpRequest", "leave", "smalltalk", "unknown"]],
                        "politeness": ["type": "integer"],
                    ],
                    "required": ["kind"],
                ],
            ],
        ]
        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "stream": true,
            "messages": msgs,
            "tools": [tool],
            "tool_choice": "auto",
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
