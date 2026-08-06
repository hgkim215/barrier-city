import Foundation
import DialogueKit

/// ⑤ LLMClient의 구체 구현. 프록시 /chat으로 짧은 답변을 스트리밍하고,
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
                    req.timeoutInterval = 12
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
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

    /// 짧은 대화 요청 바디. 게임 의도는 로컬에서 분류해 tool 호출 지연을 없앤다.
    static func body(messages: [Message]) throws -> Data {
        let msgs = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "stream": true,
            "messages": msgs,
            "max_tokens": 80,
            "temperature": 0.7,
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
