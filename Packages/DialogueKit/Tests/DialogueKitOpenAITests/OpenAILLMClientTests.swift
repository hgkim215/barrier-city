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
        XCTAssertEqual(config.ttsURL.absoluteString, "https://proxy.test/root/tts")
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

    func test_realtimeProtocol_parsesAudioAndFunctionEvents() throws {
        let audio = Data([0, 1, 2, 3])
        let audioEvent = Data(
            #"{"type":"response.output_audio.delta","item_id":"item-1","content_index":0,"delta":"\#(audio.base64EncodedString())"}"#.utf8
        )
        let functionEvent = Data(
            #"{"type":"response.function_call_arguments.done","name":"complete_order","call_id":"call-1","arguments":"{}"}"#.utf8
        )

        XCTAssertEqual(
            try RealtimeServerEvent.parse(audioEvent),
            .outputAudio(itemID: "item-1", contentIndex: 0, data: audio)
        )
        XCTAssertEqual(
            try RealtimeServerEvent.parse(functionEvent),
            .functionCall(name: "complete_order", callID: "call-1", arguments: "{}")
        )
    }

    func test_realtimeProtocol_waitsForUpdatedSessionBeforeReportingReady() throws {
        let created = try RealtimeServerEvent.parse(Data(#"{"type":"session.created"}"#.utf8))
        let updated = try RealtimeServerEvent.parse(Data(#"{"type":"session.updated"}"#.utf8))

        XCTAssertEqual(created, .sessionCreated)
        XCTAssertEqual(updated, .sessionReady)
    }

    func test_realtimeProtocol_parsesWebRTCAudioBufferLifecycle() throws {
        let started = try RealtimeServerEvent.parse(
            Data(#"{"type":"output_audio_buffer.started","response_id":"resp-1"}"#.utf8)
        )
        let cleared = try RealtimeServerEvent.parse(
            Data(#"{"type":"output_audio_buffer.cleared","response_id":"resp-1"}"#.utf8)
        )
        let stopped = try RealtimeServerEvent.parse(
            Data(#"{"type":"output_audio_buffer.stopped","response_id":"resp-1"}"#.utf8)
        )

        XCTAssertEqual(started, .outputAudioBufferStarted)
        XCTAssertEqual(cleared, .outputAudioBufferCleared)
        XCTAssertEqual(stopped, .outputAudioBufferStopped)
    }

    func test_realtimeSessionUpdate_containsGuideTranscriptionAndTools() throws {
        let data = try RealtimeClientEvent.sessionUpdate(
            instructions: "자연스럽게 대화해.",
            tools: [.init(name: "complete_order", description: "주문 완료")]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        let turnDetection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])

        XCTAssertEqual(object["type"] as? String, "session.update")
        XCTAssertEqual(session["instructions"] as? String, "자연스럽게 대화해.")
        XCTAssertEqual(transcription["model"] as? String, "gpt-4o-transcribe")
        XCTAssertEqual(transcription["language"] as? String, "ko")
        XCTAssertEqual(turnDetection["type"] as? String, "semantic_vad")
        XCTAssertEqual(turnDetection["eagerness"] as? String, "auto")
        XCTAssertEqual(turnDetection["create_response"] as? Bool, true)
        XCTAssertEqual(turnDetection["interrupt_response"] as? Bool, true)
        XCTAssertEqual(tools.first?["name"] as? String, "complete_order")
    }

    func test_realtimeClient_convertsJSONEventToWebSocketTextPayload() throws {
        let data = try RealtimeClientEvent.createResponse(instructions: "자연스럽게 응답해.")

        let text = try RealtimeWebSocketClient.outboundText(from: data)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["type"] as? String, "response.create")
    }

    func test_realtimeClient_rejectsNonUTF8WebSocketPayload() {
        XCTAssertThrowsError(
            try RealtimeWebSocketClient.outboundText(from: Data([0xFF, 0xFE]))
        )
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

    func test_realtimeTruncation_preservesPlaybackPosition() throws {
        let data = try RealtimeClientEvent.truncateAudio(
            itemID: "item-9",
            contentIndex: 0,
            audioEndMilliseconds: 1_250
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "conversation.item.truncate")
        XCTAssertEqual(object["item_id"] as? String, "item-9")
        XCTAssertEqual(object["content_index"] as? Int, 0)
        XCTAssertEqual(object["audio_end_ms"] as? Int, 1_250)
    }

    func test_realtimeMetrics_recordsConnectionTurnAndInterruptionWithoutContent() {
        let startedAt = ContinuousClock.now
        var recorder = RealtimeMetricsRecorder(transport: .webSocket)

        recorder.beginSession(at: startedAt)
        recorder.recordToken(milliseconds: 42)
        recorder.recordSessionCreated(at: startedAt.advanced(by: .milliseconds(120)))
        recorder.recordSessionReady(at: startedAt.advanced(by: .milliseconds(180)))
        recorder.recordSpeechStopped(at: startedAt.advanced(by: .seconds(1)))
        XCTAssertTrue(
            recorder.recordFirstOutput(at: startedAt.advanced(by: .milliseconds(1_350)))
        )
        recorder.recordLocalInterruptionStart(at: startedAt.advanced(by: .seconds(2)))
        XCTAssertTrue(
            recorder.recordInterruptionCompleted(at: startedAt.advanced(by: .milliseconds(2_075)))
        )
        recorder.recordError()

        XCTAssertEqual(recorder.snapshot.transport, .webSocket)
        XCTAssertEqual(recorder.snapshot.tokenMilliseconds, 42)
        XCTAssertEqual(recorder.snapshot.connectMilliseconds, 120)
        XCTAssertEqual(recorder.snapshot.readyMilliseconds, 180)
        XCTAssertEqual(recorder.snapshot.lastTurnMilliseconds, 350)
        XCTAssertEqual(recorder.snapshot.lastInterruptMilliseconds, 75)
        XCTAssertEqual(recorder.snapshot.completedTurns, 1)
        XCTAssertEqual(recorder.snapshot.interruptionCount, 1)
        XCTAssertEqual(recorder.snapshot.errorCount, 1)
    }

    func test_realtimeABMetrics_deduplicatesSnapshotsAndSeparatesTransports() {
        var comparison = RealtimeABMetrics()
        var webSocket = RealtimeMetricsSnapshot(transport: .webSocket)
        webSocket.tokenMilliseconds = 40
        webSocket.connectMilliseconds = 120
        webSocket.readyMilliseconds = 180
        webSocket.lastTurnMilliseconds = 320
        webSocket.completedTurns = 1
        webSocket.errorCount = 1

        comparison.beginSession(transport: .webSocket)
        comparison.ingest(webSocket)
        comparison.ingest(webSocket)

        var webRTC = RealtimeMetricsSnapshot(transport: .webRTC)
        webRTC.connectMilliseconds = 90
        webRTC.readyMilliseconds = 130
        webRTC.lastTurnMilliseconds = 240
        webRTC.completedTurns = 1

        comparison.beginSession(transport: .webRTC)
        comparison.ingest(webRTC)

        XCTAssertEqual(comparison.webSocket.sessionCount, 1)
        XCTAssertEqual(comparison.webSocket.turnSamples, [320])
        XCTAssertEqual(comparison.webSocket.errorCount, 1)
        XCTAssertEqual(comparison.webRTC.sessionCount, 1)
        XCTAssertEqual(comparison.webRTC.averageConnectMilliseconds, 90)
        XCTAssertEqual(comparison.webRTC.p95TurnMilliseconds, 240)
    }
}
