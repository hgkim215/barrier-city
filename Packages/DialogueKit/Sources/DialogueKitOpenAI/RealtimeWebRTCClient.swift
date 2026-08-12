import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@preconcurrency import LiveKitWebRTC

private func realtimeWebRTCLog(_ message: @autoclosure () -> String) {
#if DEBUG
    print("[Realtime][WebRTC] \(message())")
#endif
}

public struct RealtimeClientSecretProvider: Sendable {
    private let config: ProxyConfig
    private let session: URLSession

    public init(config: ProxyConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func fetch() async throws -> RealtimeClientSecret {
        realtimeWebRTCLog("ephemeral token request started")
        var request = URLRequest(url: config.realtimeTokenURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            realtimeWebRTCLog("ephemeral token request failed: non-HTTP response")
            throw RealtimeClientError.invalidResponse
        }
        realtimeWebRTCLog("ephemeral token response status=\(http.statusCode)")
        guard (200..<300).contains(http.statusCode) else {
            throw RealtimeClientError.httpStatus(http.statusCode)
        }
        let secret = try JSONDecoder().decode(RealtimeClientSecret.self, from: data)
        realtimeWebRTCLog("ephemeral token decoded; expiresAt=\(secret.expiresAt.map(String.init) ?? "unknown")")
        return secret
    }
}

/// OpenAI Realtime의 WebRTC 연결을 담당한다. 음성은 WebRTC 미디어 트랙으로,
/// 세션 이벤트와 함수 호출은 `oai-events` 데이터 채널로 전달한다.
public actor RealtimeWebRTCClient {
    public nonisolated let events: AsyncThrowingStream<RealtimeServerEvent, Error>

    private let secretProvider: RealtimeClientSecretProvider
    private let session: URLSession
    private let endpoint: URL
    private let continuation: AsyncThrowingStream<RealtimeServerEvent, Error>.Continuation
    private let delegateBridge = RealtimeWebRTCDelegateBridge()
    private var factory: LKRTCPeerConnectionFactory?
    private var peerConnection: LKRTCPeerConnection?
    private var dataChannel: LKRTCDataChannel?
    private var audioSource: LKRTCAudioSource?
    private var audioTrack: LKRTCAudioTrack?
    private static let sslInitialized = LKRTCInitializeSSL()

    public init(
        config: ProxyConfig,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/realtime/calls")!
    ) {
        secretProvider = RealtimeClientSecretProvider(config: config, session: session)
        self.session = session
        self.endpoint = endpoint

        var capturedContinuation: AsyncThrowingStream<RealtimeServerEvent, Error>.Continuation!
        events = AsyncThrowingStream { capturedContinuation = $0 }
        continuation = capturedContinuation
    }

    deinit {
        dataChannel?.close()
        peerConnection?.close()
        continuation.finish()
    }

    public func connect() async throws {
        guard peerConnection == nil else { throw RealtimeClientError.alreadyConnected }

        realtimeWebRTCLog("connect started")
        let secret = try await secretProvider.fetch()
        try Task.checkCancellation()

        _ = Self.sslInitialized
        let factory = LKRTCPeerConnectionFactory()
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: delegateBridge
        ) else {
            realtimeWebRTCLog("peer connection creation failed")
            throw RealtimeClientError.invalidResponse
        }
        realtimeWebRTCLog("peer connection created")

        let audioSource = factory.audioSource(with: constraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "barrier-city-microphone")
        guard peerConnection.add(audioTrack, streamIds: ["barrier-city-audio"]) != nil else {
            realtimeWebRTCLog("local microphone track add failed")
            peerConnection.close()
            throw RealtimeClientError.invalidResponse
        }
        realtimeWebRTCLog("local microphone track created and added")

        let channelConfiguration = LKRTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        guard let dataChannel = peerConnection.dataChannel(
            forLabel: "oai-events",
            configuration: channelConfiguration
        ) else {
            realtimeWebRTCLog("oai-events data channel creation failed")
            peerConnection.close()
            throw RealtimeClientError.channelUnavailable
        }
        realtimeWebRTCLog("oai-events data channel created; state=\(String(describing: dataChannel.readyState))")
        dataChannel.delegate = delegateBridge

        delegateBridge.onMessage = { [weak self] data in
            Task { await self?.receive(data) }
        }
        delegateBridge.onChannelStateChange = { [weak self] in
            Task { await self?.handleChannelStateChange() }
        }
        delegateBridge.onConnectionFailure = { [weak self] in
            Task { await self?.finishWithConnectionFailure() }
        }

        self.factory = factory
        self.peerConnection = peerConnection
        self.dataChannel = dataChannel
        self.audioSource = audioSource
        self.audioTrack = audioTrack

        do {
            realtimeWebRTCLog("creating SDP offer")
            let offer = try await Self.createOffer(peerConnection, constraints: constraints)
            try await Self.setLocalDescription(offer, on: peerConnection)
            realtimeWebRTCLog("local SDP set; exchanging with OpenAI")
            let answerSDP = try await exchangeSDP(offer.sdp, bearerToken: secret.value)
            let answer = LKRTCSessionDescription(type: .answer, sdp: answerSDP)
            try await Self.setRemoteDescription(answer, on: peerConnection)
            realtimeWebRTCLog("remote SDP set; waiting for data channel")
            try await waitForDataChannelOpen()
            realtimeWebRTCLog("connect completed; oai-events data channel is open")
        } catch {
            realtimeWebRTCLog("connect failed: \(error.localizedDescription)")
            await disconnect()
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        guard let dataChannel, dataChannel.readyState == .open else {
            throw RealtimeClientError.notConnected
        }
        let buffer = LKRTCDataBuffer(data: data, isBinary: false)
        guard dataChannel.sendData(buffer) else {
            throw RealtimeClientError.channelUnavailable
        }
        realtimeWebRTCLog("client event sent: \(Self.eventType(in: data))")
    }

    /// NPC 출력이 재생되는 동안 로컬 마이크 트랙을 닫아 스피커 에코가
    /// 새 사용자 턴으로 서버에 전달되지 않게 한다.
    public func setMicrophoneEnabled(_ enabled: Bool) {
        audioTrack?.isEnabled = enabled
        realtimeWebRTCLog("microphone track enabled=\(enabled)")
    }

    public func disconnect() async {
        realtimeWebRTCLog("disconnect started")
        delegateBridge.clearCallbacks()
        dataChannel?.delegate = nil
        dataChannel?.close()
        peerConnection?.delegate = nil
        peerConnection?.close()
        dataChannel = nil
        peerConnection = nil
        audioTrack = nil
        audioSource = nil
        factory = nil
        continuation.finish()
        realtimeWebRTCLog("disconnect completed")
    }

    private func exchangeSDP(_ offer: String, bearerToken: String) async throws -> String {
        let request = Self.makeSDPRequest(
            endpoint: endpoint,
            offer: offer,
            bearerToken: bearerToken
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            realtimeWebRTCLog("SDP exchange failed: non-HTTP response")
            throw RealtimeClientError.invalidResponse
        }
        realtimeWebRTCLog("SDP exchange response status=\(http.statusCode)")
        guard (200..<300).contains(http.statusCode) else {
            throw RealtimeClientError.httpStatus(http.statusCode)
        }
        guard let answer = String(data: data, encoding: .utf8), !answer.isEmpty else {
            throw RealtimeClientError.invalidResponse
        }
        return answer
    }

    static func makeSDPRequest(
        endpoint: URL,
        offer: String,
        bearerToken: String
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offer.utf8)
        return request
    }

    private func waitForDataChannelOpen() async throws {
        for _ in 0..<100 {
            guard let dataChannel else { throw RealtimeClientError.notConnected }
            if dataChannel.readyState == .open { return }
            if dataChannel.readyState == .closed { throw RealtimeClientError.channelUnavailable }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RealtimeClientError.channelUnavailable
    }

    private func receive(_ data: Data) {
        do {
            let event = try RealtimeServerEvent.parse(data)
            realtimeWebRTCLog("server event received: \(Self.eventSummary(event))")
            continuation.yield(event)
        } catch {
            realtimeWebRTCLog("server event parse failed: \(error.localizedDescription)")
            continuation.finish(throwing: error)
        }
    }

    private func handleChannelStateChange() {
        guard let dataChannel, dataChannel.readyState == .closed else { return }
        realtimeWebRTCLog("oai-events data channel closed")
        continuation.finish()
    }

    private func finishWithConnectionFailure() {
        realtimeWebRTCLog("peer connection failed or closed")
        continuation.finish(throwing: RealtimeClientError.notConnected)
    }

    private static func eventType(in data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return "unknown"
        }
        return type
    }

    private static func eventSummary(_ event: RealtimeServerEvent) -> String {
        switch event {
        case .sessionReady: "session.updated"
        case .responseCreated: "response.created"
        case .speechStarted: "input_audio_buffer.speech_started"
        case .speechStopped: "input_audio_buffer.speech_stopped"
        case .inputTranscriptDelta(let text): "input transcript delta=\(text.debugDescription)"
        case .inputTranscriptDone(let text): "input transcript completed=\(text.debugDescription)"
        case .outputTranscriptDelta: "output transcript delta"
        case .outputTranscriptDone: "output transcript completed"
        case .outputAudioStarted: "output_audio_buffer.started"
        case .outputAudioStopped: "output_audio_buffer.stopped"
        case .outputAudioCleared: "output_audio_buffer.cleared"
        case .functionCall(let name, _, _): "function call name=\(name)"
        case .responseDone: "response.done"
        case .error(let message): "error=\(message)"
        case .ignored(let type): "ignored type=\(type)"
        }
    }

    private static func createOffer(
        _ peerConnection: LKRTCPeerConnection,
        constraints: LKRTCMediaConstraints
    ) async throws -> LKRTCSessionDescription {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<LKRTCSessionDescription, Error>) in
            peerConnection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: RealtimeClientError.invalidResponse)
                }
            }
        }
    }

    private static func setLocalDescription(
        _ description: LKRTCSessionDescription,
        on peerConnection: LKRTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func setRemoteDescription(
        _ description: LKRTCSessionDescription,
        on peerConnection: LKRTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

}

private final class RealtimeWebRTCDelegateBridge: NSObject,
    LKRTCPeerConnectionDelegate,
    LKRTCDataChannelDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var messageHandler: (@Sendable (Data) -> Void)?
    private var channelStateHandler: (@Sendable () -> Void)?
    private var connectionFailureHandler: (@Sendable () -> Void)?

    var onMessage: (@Sendable (Data) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }

    var onChannelStateChange: (@Sendable () -> Void)? {
        get { lock.withLock { channelStateHandler } }
        set { lock.withLock { channelStateHandler = newValue } }
    }

    var onConnectionFailure: (@Sendable () -> Void)? {
        get { lock.withLock { connectionFailureHandler } }
        set { lock.withLock { connectionFailureHandler = newValue } }
    }

    func clearCallbacks() {
        lock.withLock {
            messageHandler = nil
            channelStateHandler = nil
            connectionFailureHandler = nil
        }
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        realtimeWebRTCLog("data channel state=\(String(describing: dataChannel.readyState))")
        onChannelStateChange?()
    }

    func dataChannel(
        _ dataChannel: LKRTCDataChannel,
        didReceiveMessageWith buffer: LKRTCDataBuffer
    ) {
        onMessage?(buffer.data)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange stateChanged: LKRTCSignalingState
    ) {
        realtimeWebRTCLog("signaling state=\(String(describing: stateChanged))")
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceConnectionState
    ) {
        realtimeWebRTCLog("ICE connection state=\(String(describing: newState))")
        if newState == .failed || newState == .closed {
            onConnectionFailure?()
        }
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceGatheringState
    ) {
        realtimeWebRTCLog("ICE gathering state=\(String(describing: newState))")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didGenerate candidate: LKRTCIceCandidate
    ) {}

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove candidates: [LKRTCIceCandidate]
    ) {}

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didOpen dataChannel: LKRTCDataChannel
    ) {
        realtimeWebRTCLog("remote data channel opened: \(dataChannel.label)")
    }
}
