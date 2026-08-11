import Foundation

public enum RealtimeAudioDelivery: Sendable {
    /// PCM 오디오를 Realtime 이벤트로 주고받으며 앱이 캡처와 재생을 담당한다.
    case events
    /// WebRTC 미디어 트랙이 마이크 캡처와 모델 음성 재생을 담당한다.
    case mediaTrack
}

/// Realtime 대화 세션이 구체적인 네트워크 구현에 의존하지 않게 하는 최소 전송 계약.
/// 구현체는 OpenAI 서버 이벤트를 동일한 파서 모델로 전달해야 한다.
public protocol RealtimeTransport: Actor {
    nonisolated var kind: RealtimeTransportKind { get }
    nonisolated var audioDelivery: RealtimeAudioDelivery { get }
    nonisolated var events: AsyncThrowingStream<RealtimeServerEvent, Error> { get }
    var lastTokenRequestMilliseconds: Int? { get }

    func connect() async throws
    func send(_ data: Data) async throws
    func disconnect() async
}
