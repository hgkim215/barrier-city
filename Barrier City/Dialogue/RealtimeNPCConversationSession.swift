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
        case outputAudioStarted
        case outputAudioStopped
        case microphoneReady
        case functionCall(name: String, callID: String, arguments: String)
        case responseDone
        case failure(String)
    }

    private let client: RealtimeWebRTCClient
    private let audioSession = RealtimeMediaTrackAudioSession()
    private var receiveTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var microphoneResumeTask: Task<Void, Never>?
    private var configurationContinuation: CheckedContinuation<Void, Error>?
    private var eventHandler: (@MainActor (Event) -> Void)?
    private var isStarted = false
    private var outputAudioIsPlaying = false

    /// 실제 출력 종료 직후 남는 방 안의 잔향까지 서버 VAD에 들어가지 않도록 둔다.
    private static let microphoneResumeDelay = Duration.milliseconds(250)

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
            await suspendMicrophoneForResponse()

            receiveTask = Task { @MainActor [weak self, client] in
                do {
                    for try await event in client.events {
                        await self?.handle(event)
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
            try await requestResponse(
                instructions: """
                Respond ONLY in Korean. Briefly greet the visitor in natural spoken Korean,
                then stop and wait for their reply. Do not use any English words.
                """
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
        await suspendMicrophoneForResponse()
        try await client.send(
            RealtimeClientEvent.functionOutput(callID: callID, output: output)
        )
        try await requestResponse()
    }

    /// 서버 VAD는 발화 경계와 transcript만 만들고, 유효한 사용자 transcript를 받은 뒤
    /// 앱이 명시적으로 응답을 생성한다.
    func requestResponse(instructions: String? = nil) async throws {
        guard isStarted else { throw RealtimeClientError.notConnected }
        await suspendMicrophoneForResponse()
        try await client.send(RealtimeClientEvent.createResponse(instructions: instructions))
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
        microphoneResumeTask?.cancel()
        microphoneResumeTask = nil
        pendingConfiguration?.cancel()
        pendingReceive?.cancel()
        outputAudioIsPlaying = false

        audioSession.stop()
        await client.disconnect()
        await pendingConfiguration?.value
        await pendingReceive?.value
        realtimeConversationLog("session stopped")
    }

    private func handle(_ event: RealtimeServerEvent) async {
        switch event {
        case .sessionReady:
            realtimeConversationLog("event: session ready")
            resumeConfiguration()
            eventHandler?(.sessionReady)
        case .responseCreated:
            await suspendMicrophoneForResponse()
        case .speechStarted:
            realtimeConversationLog("event: user speech started")
            eventHandler?(.speechStarted)
        case .speechStopped:
            realtimeConversationLog("event: user speech stopped; waiting for completed transcript")
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
        case .outputAudioStarted:
            outputAudioIsPlaying = true
            await suspendMicrophoneForResponse()
            realtimeConversationLog("event: output audio started; microphone suspended")
            eventHandler?(.outputAudioStarted)
        case .outputAudioStopped:
            outputAudioIsPlaying = false
            realtimeConversationLog("event: output audio stopped")
            eventHandler?(.outputAudioStopped)
            scheduleMicrophoneResume()
        case .outputAudioCleared:
            outputAudioIsPlaying = false
            realtimeConversationLog("event: output audio cleared")
            eventHandler?(.outputAudioStopped)
            scheduleMicrophoneResume()
        case .functionCall(let name, let callID, let arguments):
            eventHandler?(.functionCall(name: name, callID: callID, arguments: arguments))
        case .responseDone:
            realtimeConversationLog("event: response done")
            if !outputAudioIsPlaying { scheduleMicrophoneResume() }
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

    private func suspendMicrophoneForResponse() async {
        microphoneResumeTask?.cancel()
        microphoneResumeTask = nil
        await client.setMicrophoneEnabled(false)
    }

    private func scheduleMicrophoneResume() {
        microphoneResumeTask?.cancel()
        microphoneResumeTask = Task { @MainActor [weak self, client] in
            do {
                try await Task.sleep(for: Self.microphoneResumeDelay)
            } catch {
                return
            }
            guard let self, self.isStarted, !self.outputAudioIsPlaying else { return }
            await client.setMicrophoneEnabled(true)
            self.microphoneResumeTask = nil
            realtimeConversationLog("microphone resumed after output echo tail")
            self.eventHandler?(.microphoneReady)
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
