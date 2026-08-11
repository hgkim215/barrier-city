import Foundation

/// Realtime 대화 세션이 구체적인 네트워크 구현에 의존하지 않게 하는 최소 전송 계약.
/// 구현체는 OpenAI 서버 이벤트를 동일한 파서 모델로 전달해야 한다.
public protocol RealtimeTransport: Actor {
    nonisolated var kind: RealtimeTransportKind { get }
    nonisolated var events: AsyncThrowingStream<RealtimeServerEvent, Error> { get }
    var lastTokenRequestMilliseconds: Int? { get }

    func connect() async throws
    func send(_ data: Data) async throws
    func disconnect() async
}
