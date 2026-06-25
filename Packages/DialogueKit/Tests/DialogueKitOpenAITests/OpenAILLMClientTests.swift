import XCTest
@testable import DialogueKitOpenAI
import DialogueKit

// 네트워크 없이 SSE 바이트를 주입하는 URLProtocol 목.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubData = Data()
    nonisolated(unsafe) static var stubContentType = "text/event-stream"
    nonisolated(unsafe) static var stubStatus = 200

    static func stub(body: Data, contentType: String = "text/event-stream", status: Int = 200) {
        stubData = body; stubContentType = contentType; stubStatus = status
    }
    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.stubStatus,
                                   httpVersion: nil, headerFields: ["Content-Type": Self.stubContentType])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OpenAILLMClientTests: XCTestCase {
    private func makeClient() -> OpenAILLMClient {
        OpenAILLMClient(config: ProxyConfig(base: URL(string: "https://proxy.test")!),
                        session: MockURLProtocol.session())
    }

    func test_streamsTokensAndDone_fromSSEBytes() async throws {
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"안녕\"}}]}\n\n" +
                  "data: {\"choices\":[{\"delta\":{\"content\":\"하세요\"}}]}\n\n" +
                  "data: [DONE]\n\n"
        MockURLProtocol.stub(body: Data(sse.utf8))
        var tokens: [String] = []; var sawDone = false
        for try await ev in makeClient().stream(messages: [Message(role: .user, content: "hi")]) {
            switch ev {
            case .token(let t): tokens.append(t)
            case .done: sawDone = true
            default: break
            }
        }
        XCTAssertEqual(tokens, ["안녕", "하세요"])
        XCTAssertTrue(sawDone)
    }

    func test_non2xx_throws() async {
        MockURLProtocol.stub(body: Data("err".utf8), status: 500)
        do {
            for try await _ in makeClient().stream(messages: []) {}
            XCTFail("expected throw on 500")
        } catch { /* expected */ }
    }

    func test_body_includesModelStreamToolAndMessages() throws {
        let data = try OpenAILLMClient.body(messages: [
            Message(role: .system, content: "S"),
            Message(role: .user, content: "U"),
        ])
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(obj["stream"] as? Bool, true)
        XCTAssertNotNil(obj["tools"])
        let msgs = obj["messages"] as! [[String: String]]
        XCTAssertEqual(msgs.first?["role"], "system")
        XCTAssertEqual(msgs.last?["content"], "U")
    }
}
