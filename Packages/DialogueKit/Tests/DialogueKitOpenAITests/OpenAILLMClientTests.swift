import XCTest
@testable import DialogueKitOpenAI
import DialogueKit

// 네트워크 없이 SSE 바이트를 주입하는 URLProtocol 목.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubData = Data()
    nonisolated(unsafe) static var stubContentType = "text/event-stream"
    nonisolated(unsafe) static var stubStatus = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?

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
        Self.lastRequest = request
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

    func test_body_isShortStreamingRequest_withoutToolRoundTrip() throws {
        let data = try OpenAILLMClient.body(messages: [
            Message(role: .system, content: "S"),
            Message(role: .user, content: "U"),
        ])
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(obj["stream"] as? Bool, true)
        XCTAssertNil(obj["tools"])
        XCTAssertEqual(obj["max_tokens"] as? Int, 120)
        XCTAssertEqual(obj["temperature"] as? Double, 0.8)
        XCTAssertEqual(obj["frequency_penalty"] as? Double, 0.2)
        let msgs = obj["messages"] as! [[String: String]]
        XCTAssertEqual(msgs.first?["role"], "system")
        XCTAssertEqual(msgs.last?["content"], "U")
    }

    func test_proxyConfig_exposesRestrictedRealtimeTokenEndpoint() {
        let config = ProxyConfig(base: URL(string: "https://proxy.test/root")!)

        XCTAssertEqual(config.chatURL.absoluteString, "https://proxy.test/root/chat")
        XCTAssertEqual(config.realtimeTokenURL.absoluteString,
                       "https://proxy.test/root/realtime-token")
    }

    func test_realtimeSecretProvider_postsToRestrictedEndpoint() async throws {
        MockURLProtocol.stub(
            body: Data(#"{"value":"ek_test","expires_at":12345}"#.utf8),
            contentType: "application/json"
        )
        let provider = RealtimeClientSecretProvider(
            config: ProxyConfig(base: URL(string: "https://proxy.test")!),
            session: MockURLProtocol.session()
        )

        let secret = try await provider.fetch()

        XCTAssertEqual(secret, RealtimeClientSecret(value: "ek_test", expiresAt: 12345))
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString,
                       "https://proxy.test/realtime-token")
    }

    func test_realtimeProtocol_parsesFunctionEvent() throws {
        let functionEvent = Data(
            #"{"type":"response.function_call_arguments.done","name":"complete_order","call_id":"call-1","arguments":"{}"}"#.utf8
        )

        XCTAssertEqual(
            try RealtimeServerEvent.parse(functionEvent),
            .functionCall(name: "complete_order", callID: "call-1", arguments: "{}")
        )
    }

    func test_realtimeProtocol_waitsForUpdatedSessionBeforeReportingReady() throws {
        let created = try RealtimeServerEvent.parse(Data(#"{"type":"session.created"}"#.utf8))
        let updated = try RealtimeServerEvent.parse(Data(#"{"type":"session.updated"}"#.utf8))

        XCTAssertEqual(created, .ignored("session.created"))
        XCTAssertEqual(updated, .sessionReady)
    }

    func test_realtimeProtocol_parsesResponseAndOutputPlaybackLifecycle() throws {
        let created = try RealtimeServerEvent.parse(
            Data(#"{"type":"response.created"}"#.utf8)
        )
        let started = try RealtimeServerEvent.parse(
            Data(#"{"type":"output_audio_buffer.started"}"#.utf8)
        )
        let stopped = try RealtimeServerEvent.parse(
            Data(#"{"type":"output_audio_buffer.stopped"}"#.utf8)
        )
        let cleared = try RealtimeServerEvent.parse(
            Data(#"{"type":"output_audio_buffer.cleared"}"#.utf8)
        )

        XCTAssertEqual(created, .responseCreated)
        XCTAssertEqual(started, .outputAudioStarted)
        XCTAssertEqual(stopped, .outputAudioStopped)
        XCTAssertEqual(cleared, .outputAudioCleared)
    }

    func test_realtimeSessionUpdate_containsGuideTranscriptionAndTools() throws {
        let data = try RealtimeClientEvent.sessionUpdate(
            instructions: "자연스럽게 대화해.",
            tools: [
                .init(
                    name: "complete_order",
                    description: "주문 완료",
                    parameters: [
                        .init(
                            name: "item",
                            type: .string,
                            description: "메뉴 식별자",
                            allowedStringValues: ["rainbow_smoothie"]
                        ),
                        .init(
                            name: "quantity",
                            type: .integer,
                            description: "수량",
                            minimumIntegerValue: 1,
                            maximumIntegerValue: 1
                        ),
                    ]
                ),
            ]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        let turnDetection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        let parameters = try XCTUnwrap(tools.first?["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let item = try XCTUnwrap(properties["item"] as? [String: Any])
        let quantity = try XCTUnwrap(properties["quantity"] as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "session.update")
        XCTAssertEqual(session["instructions"] as? String, "자연스럽게 대화해.")
        XCTAssertEqual(transcription["model"] as? String, "gpt-4o-transcribe")
        XCTAssertEqual(transcription["language"] as? String, "ko")
        XCTAssertEqual(turnDetection["type"] as? String, "server_vad")
        XCTAssertEqual(turnDetection["threshold"] as? Double, 0.65)
        XCTAssertEqual(turnDetection["prefix_padding_ms"] as? Int, 300)
        XCTAssertEqual(turnDetection["silence_duration_ms"] as? Int, 700)
        XCTAssertEqual(turnDetection["create_response"] as? Bool, false)
        XCTAssertEqual(turnDetection["interrupt_response"] as? Bool, false)
        XCTAssertEqual(tools.first?["name"] as? String, "complete_order")
        XCTAssertEqual(parameters["required"] as? [String], ["item", "quantity"])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        XCTAssertEqual(item["enum"] as? [String], ["rainbow_smoothie"])
        XCTAssertEqual(quantity["minimum"] as? Int, 1)
        XCTAssertEqual(quantity["maximum"] as? Int, 1)
    }

    func test_realtimeResponse_canOverrideInstructionsAndDisableTools() throws {
        let data = try RealtimeClientEvent.createResponse(
            instructions: "호감도 0.20",
            toolChoice: .none
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let response = try XCTUnwrap(object["response"] as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "response.create")
        XCTAssertEqual(response["instructions"] as? String, "호감도 0.20")
        XCTAssertEqual(response["tool_choice"] as? String, "none")
        XCTAssertEqual(response["output_modalities"] as? [String], ["audio"])
    }

    func test_realtimeResponse_canRequireOnlyTheValidatedOrderTool() throws {
        let orderTool = RealtimeFunctionTool(
            name: "place_order",
            description: "Place a validated order.",
            parameters: [
                .init(
                    name: "item",
                    type: .string,
                    description: "Canonical item.",
                    allowedStringValues: ["rainbow_smoothie"]
                ),
                .init(
                    name: "quantity",
                    type: .integer,
                    description: "Cup count.",
                    minimumIntegerValue: 1,
                    maximumIntegerValue: 1
                ),
            ]
        )
        let data = try RealtimeClientEvent.createResponse(
            instructions: "Call the validated order tool.",
            toolChoice: .required,
            tools: [orderTool]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let response = try XCTUnwrap(object["response"] as? [String: Any])
        let tools = try XCTUnwrap(response["tools"] as? [[String: Any]])

        XCTAssertEqual(response["tool_choice"] as? String, "required")
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["name"] as? String, "place_order")
    }

    func test_realtimeWebRTC_postsSDPWithEphemeralBearerToken() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.openai.test/v1/realtime/calls"))

        let request = RealtimeWebRTCClient.makeSDPRequest(
            endpoint: endpoint,
            offer: "v=0\r\no=test-offer",
            bearerToken: "ephemeral-test-token"
        )

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/sdp")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer ephemeral-test-token"
        )
        XCTAssertEqual(request.httpBody, Data("v=0\r\no=test-offer".utf8))
    }

}
