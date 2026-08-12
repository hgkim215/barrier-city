import Foundation
import DialogueKitOpenAI

private func realtimeConversationLog(_ message: @autoclosure () -> String) {
#if DEBUG
    print("[Realtime][Conversation] \(message())")
#endif
}

/// NPC 한 명과의 Realtime WebRTC 대화 수명주기를 관리한다.
@MainActor
final class RealtimeNPCConversationSession {
    enum Event: Sendable {
        case sessionReady
        case speechStarted
        case speechStopped
        case inputTranscriptDelta(String)
        case inputTranscriptDone(String)
        case outputTranscriptDelta(String)
        case outputTranscriptDone(String)
        case functionCall(name: String, callID: String, arguments: String)
        case responseDone
        case failure(String)
    }

    private let client: RealtimeWebRTCClient
    private let audioSession = RealtimeMediaTrackAudioSession()
    private var receiveTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var configurationContinuation: CheckedContinuation<Void, Error>?
    private var eventHandler: (@MainActor (Event) -> Void)?
    private var isStarted = false

    init(client: RealtimeWebRTCClient = RealtimeWebRTCClient(config: AppConfig.proxy)) {
        self.client = client
    }

    func start(
        instructions: String,
        tools: [RealtimeFunctionTool],
        onEvent: @escaping @MainActor (Event) -> Void
    ) async throws {
        guard !isStarted else { throw RealtimeClientError.alreadyConnected }
        try Task.checkCancellation()
        isStarted = true
        eventHandler = onEvent
        realtimeConversationLog("session start requested")

        do {
            try await audioSession.start()
            realtimeConversationLog("audio session ready")
            try await client.connect()
            realtimeConversationLog("WebRTC client connected")

            receiveTask = Task { @MainActor [weak self, client] in
                do {
                    for try await event in client.events {
                        self?.handle(event)
                    }
                } catch is CancellationError {
                    realtimeConversationLog("event receive task cancelled")
                    self?.resumeConfiguration(throwing: CancellationError())
                } catch {
                    realtimeConversationLog("event receive failed: \(error.localizedDescription)")
                    self?.resumeConfiguration(throwing: error)
                    self?.eventHandler?(.failure(error.localizedDescription))
                }
            }

            try await configureSession(instructions: instructions, tools: tools)
            realtimeConversationLog("Realtime session configured")
            try Task.checkCancellation()
            try await client.send(
                RealtimeClientEvent.createResponse(
                    instructions: """
                    Respond ONLY in Korean. Briefly greet the visitor in natural spoken Korean,
                    then stop and wait for their reply. Do not use any English words.
                    """
                )
            )
            realtimeConversationLog("initial NPC greeting requested")
        } catch {
            realtimeConversationLog("session start failed: \(error.localizedDescription)")
            await stop()
            throw error
        }
    }

    func completeFunctionCall(callID: String, output: String) async throws {
        guard isStarted else { throw RealtimeClientError.notConnected }
        try await client.send(
            RealtimeClientEvent.functionOutput(callID: callID, output: output)
        )
        try await client.send(RealtimeClientEvent.createResponse())
    }

    func stop() async {
        guard isStarted else {
            realtimeConversationLog("stop skipped; session was not started")
            return
        }
        realtimeConversationLog("session stop requested")
        isStarted = false
        eventHandler = nil
        resumeConfiguration(throwing: CancellationError())

        let pendingConfiguration = configurationTask
        let pendingReceive = receiveTask
        configurationTask = nil
        receiveTask = nil
        pendingConfiguration?.cancel()
        pendingReceive?.cancel()

        audioSession.stop()
        await client.disconnect()
        await pendingConfiguration?.value
        await pendingReceive?.value
        realtimeConversationLog("session stopped")
    }

    private func handle(_ event: RealtimeServerEvent) {
        switch event {
        case .sessionReady:
            realtimeConversationLog("event: session ready")
            resumeConfiguration()
            eventHandler?(.sessionReady)
        case .speechStarted:
            realtimeConversationLog("event: user speech started")
            eventHandler?(.speechStarted)
        case .speechStopped:
            realtimeConversationLog("event: user speech stopped; automatic response should follow")
            eventHandler?(.speechStopped)
        case .inputTranscriptDelta(let text):
            realtimeConversationLog("event: input transcript delta=\(text.debugDescription)")
            eventHandler?(.inputTranscriptDelta(text))
        case .inputTranscriptDone(let text):
            realtimeConversationLog("event: input transcript completed=\(text.debugDescription)")
            eventHandler?(.inputTranscriptDone(text))
        case .outputTranscriptDelta(let text):
            eventHandler?(.outputTranscriptDelta(text))
        case .outputTranscriptDone(let text):
            eventHandler?(.outputTranscriptDone(text))
        case .functionCall(let name, let callID, let arguments):
            eventHandler?(.functionCall(name: name, callID: callID, arguments: arguments))
        case .responseDone:
            realtimeConversationLog("event: response done")
            eventHandler?(.responseDone)
        case .error(let message):
            realtimeConversationLog("event: server error=\(message)")
            let error = NSError(
                domain: "OpenAI.Realtime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            resumeConfiguration(throwing: error)
            eventHandler?(.failure(message))
        case .ignored:
            break
        }
    }

    private func configureSession(
        instructions: String,
        tools: [RealtimeFunctionTool]
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                configurationContinuation = continuation
                configurationTask = Task { @MainActor [weak self, client] in
                    do {
                        try await client.send(
                            RealtimeClientEvent.sessionUpdate(
                                instructions: instructions,
                                tools: tools
                            )
                        )
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.resumeConfiguration(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeConfiguration(throwing: CancellationError())
            }
        }
    }

    private func resumeConfiguration(throwing error: Error? = nil) {
        guard let continuation = configurationContinuation else { return }
        configurationContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
