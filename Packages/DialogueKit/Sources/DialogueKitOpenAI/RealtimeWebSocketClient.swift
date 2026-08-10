import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        return try JSONDecoder().decode(RealtimeClientSecret.self, from: data)
    }
}

public actor RealtimeWebSocketClient {
    public nonisolated let events: AsyncThrowingStream<RealtimeServerEvent, Error>

    private let secretProvider: RealtimeClientSecretProvider
    private let session: URLSession
    private let endpoint: URL
    private let continuation: AsyncThrowingStream<RealtimeServerEvent, Error>.Continuation
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    public init(
        config: ProxyConfig,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")!
    ) {
        self.secretProvider = RealtimeClientSecretProvider(config: config, session: session)
        self.session = session
        self.endpoint = endpoint

        var capturedContinuation: AsyncThrowingStream<RealtimeServerEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation
    }

    deinit {
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    public func connect() async throws {
        guard socket == nil else { throw RealtimeClientError.alreadyConnected }
        let secret = try await secretProvider.fetch()
        let task = session.webSocketTask(
            with: endpoint,
            protocols: ["realtime", "openai-insecure-api-key.\(secret.value)"]
        )
        socket = task
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveMessages(from: task)
        }
    }

    public func send(_ data: Data) async throws {
        guard let socket else { throw RealtimeClientError.notConnected }
        try await socket.send(.string(try Self.outboundText(from: data)))
    }

    static func outboundText(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeClientError.invalidEvent
        }
        return text
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        continuation.finish()
    }

    private func receiveMessages(from task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let value):
                    data = value
                case .string(let value):
                    data = Data(value.utf8)
                @unknown default:
                    continue
                }
                continuation.yield(try RealtimeServerEvent.parse(data))
            }
        } catch is CancellationError {
            // 정상 종료
        } catch {
            continuation.finish(throwing: error)
            socket = nil
        }
    }
}
