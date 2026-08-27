import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@preconcurrency import LiveKitWebRTC

public struct RealtimeClientSecretProvider: Sendable {
    private let config: ProxyConfig
    private let session: URLSession

    public init(config: ProxyConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func fetch() async throws -> RealtimeClientSecret {
        var request = URLRequest(url: config.realtimeTokenURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RealtimeClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RealtimeClientError.httpStatus(http.statusCode)
        }
        let secret = try JSONDecoder().decode(RealtimeClientSecret.self, from: data)
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
    /// WebRTC는 기본값(useManualAudio=NO)에서 오디오 트랙이 준비되는 즉시 스스로
    /// AVAudioSession을 초기화·활성화한다. 이 앱은 AudioSessionCoordinator가
    /// AVAudioSession을 직접 구성/활성화해 다른 오디오(효과음 등)와 조율하므로, 그
    /// 자동 관리와 충돌한다 — 특히 RealtimePreconnect로 미리 만들어둔 오디오 트랙을
    /// 재사용할 때, 실제 대화 시작 시 코디네이터가 세션을 다시 구성/활성화해도
    /// WebRTC는 이를 모른 채 preconnect 시점에 초기화했던(이제 무효가 된) 오디오
    /// 유닛을 그대로 쓰려 해 마이크 입력·음성 출력이 통째로 죽는다. 수동 모드로
    /// 두고 앱이 setPlatformAudioSessionActive로 명시적으로 켜고 끄게 한다.
    private static let audioSessionManualModeConfigured: Void = {
        let session = LKRTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
    }()

    /// 앱의 AudioSessionCoordinator가 AVAudioSession을 완전히 구성·활성화한
    /// "뒤"에만 켜고, 세션을 건드리기 "전"에 꺼야 한다 — AVAudioEngine을 세션 전환
    /// 전에 멈춰야 하는 것과 같은 이유다.
    public static func setPlatformAudioSessionActive(_ active: Bool) {
        _ = Self.audioSessionManualModeConfigured
        LKRTCAudioSession.sharedInstance().isAudioEnabled = active
    }

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

    /// 이미 연결(peerConnection 존재)돼 있는지. 몰입 공간 진입 시 미리 연결해둔
    /// 클라이언트를 실제 대화 시작 시 재사용할 때, connect()를 다시 호출해
    /// alreadyConnected로 실패하지 않도록 호출부가 먼저 확인하는 용도.
    public var isConnected: Bool { peerConnection != nil }

    public func connect() async throws {
        guard peerConnection == nil else { throw RealtimeClientError.alreadyConnected }

        let secret = try await secretProvider.fetch()
        try Task.checkCancellation()

        _ = Self.sslInitialized
        _ = Self.audioSessionManualModeConfigured
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
            throw RealtimeClientError.invalidResponse
        }

        let audioSource = factory.audioSource(with: constraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "barrier-city-microphone")
        guard peerConnection.add(audioTrack, streamIds: ["barrier-city-audio"]) != nil else {
            peerConnection.close()
            throw RealtimeClientError.invalidResponse
        }

        let channelConfiguration = LKRTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        guard let dataChannel = peerConnection.dataChannel(
            forLabel: "oai-events",
            configuration: channelConfiguration
        ) else {
            peerConnection.close()
            throw RealtimeClientError.channelUnavailable
        }
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
            let offer = try await Self.createOffer(peerConnection, constraints: constraints)
            try await Self.setLocalDescription(offer, on: peerConnection)
            let answerSDP = try await exchangeSDP(offer.sdp, bearerToken: secret.value)
            let answer = LKRTCSessionDescription(type: .answer, sdp: answerSDP)
            try await Self.setRemoteDescription(answer, on: peerConnection)
            try await waitForDataChannelOpen()
        } catch {
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
    }

    /// NPC 출력이 재생되는 동안 로컬 마이크 트랙을 닫아 스피커 에코가
    /// 새 사용자 턴으로 서버에 전달되지 않게 한다.
    public func setMicrophoneEnabled(_ enabled: Bool) {
        audioTrack?.isEnabled = enabled
    }

    public func disconnect() async {
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
    }

    private func exchangeSDP(_ offer: String, bearerToken: String) async throws -> String {
        let request = Self.makeSDPRequest(
            endpoint: endpoint,
            offer: offer,
            bearerToken: bearerToken
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RealtimeClientError.invalidResponse
        }
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
            continuation.yield(event)
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func handleChannelStateChange() {
        guard let dataChannel, dataChannel.readyState == .closed else { return }
        continuation.finish()
    }

    private func finishWithConnectionFailure() {
        continuation.finish(throwing: RealtimeClientError.notConnected)
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
    ) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceConnectionState
    ) {
        if newState == .failed || newState == .closed {
            onConnectionFailure?()
        }
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceGatheringState
    ) {}

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
    ) {}
}
