import Foundation
import DialogueKit
import DialogueKitOpenAI

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
    private var responseIsInFlight = false
    private var outputAudioIsPlaying = false

    /// 실제 출력 종료 직후 남는 방 안의 잔향까지 서버 VAD에 들어가지 않도록 둔다.
    private static let microphoneResumeDelay = Duration.milliseconds(250)

    init(client: RealtimeWebRTCClient = RealtimeWebRTCClient(config: AppConfig.proxy)) {
        self.client = client
    }

    func start(
        instructions: String,
        openingInstructions: String,
        tools: [RealtimeFunctionTool],
        onEvent: @escaping @MainActor (Event) -> Void
    ) async throws {
        guard !isStarted else { throw RealtimeClientError.alreadyConnected }
        try Task.checkCancellation()
        isStarted = true
        eventHandler = onEvent

        do {
            try await audioSession.start()
            // 몰입 공간 진입 시 미리 연결해둔 클라이언트가 주어졌다면(RealtimePreconnect)
            // 다시 connect()를 호출하지 않는다 — 이미 연결된 클라이언트에 또 호출하면
            // alreadyConnected로 실패한다.
            if await !client.isConnected {
                try await client.connect()
            }
            pauseMicrophoneAcceptanceForResponse()

            receiveTask = Task { @MainActor [weak self, client] in
                do {
                    for try await event in client.events {
                        await self?.handle(event)
                    }
                } catch is CancellationError {
                    self?.resumeConfiguration(throwing: CancellationError())
                } catch {
                    self?.resumeConfiguration(throwing: error)
                    self?.eventHandler?(.failure(error.localizedDescription))
                }
            }

            try await configureSession(instructions: instructions, tools: tools)
            try Task.checkCancellation()
            try await requestResponse(
                instructions: """
                \(instructions)

                # 앱이 관리하는 이번 응답의 대화 단계
                \(openingInstructions)
                """,
                toolChoice: .none
            )
        } catch {
            await stop()
            throw error
        }
    }

    /// 한 응답 안에서 모델이 여러 함수를 불렀을 때(지침 위반)도 각 callID에 대한 output을
    /// 빠짐없이 보낸다 — 하나라도 응답 없는 tool call로 남으면 대화 상태가 꼬인다. 모든
    /// output을 보낸 뒤 후속 응답은 한 번만 요청한다.
    func completeFunctionCalls(
        _ calls: [(callID: String, output: String)],
        responseInstructions: String
    ) async throws {
        guard isStarted else { throw RealtimeClientError.notConnected }
        pauseMicrophoneAcceptanceForResponse()
        for call in calls {
            try await client.send(
                RealtimeClientEvent.functionOutput(callID: call.callID, output: call.output)
            )
        }
        // 도구 결과를 설명하는 후속 응답에서는 도구를 다시 호출하지 못하게 해
        // 실패한 주문 검증이 자동 재시도 루프로 이어지는 것을 차단한다.
        try await requestResponse(
            instructions: responseInstructions,
            toolChoice: .none
        )
    }

    /// 서버 VAD는 발화 경계와 transcript만 만들고, 유효한 사용자 transcript를 받은 뒤
    /// 앱이 명시적으로 응답을 생성한다.
    func requestResponse(
        instructions: String? = nil,
        toolChoice: RealtimeToolChoice = .auto,
        tools: [RealtimeFunctionTool]? = nil
    ) async throws {
        guard isStarted else { throw RealtimeClientError.notConnected }
        pauseMicrophoneAcceptanceForResponse()
        responseIsInFlight = true
        try await client.send(
            RealtimeClientEvent.createResponse(
                instructions: instructions,
                toolChoice: toolChoice,
                tools: tools
            )
        )
    }

    func stop() async {
        guard isStarted else { return }
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
        responseIsInFlight = false
        outputAudioIsPlaying = false

        audioSession.stop()
        await client.disconnect()
        await pendingConfiguration?.value
        await pendingReceive?.value
    }

    private func handle(_ event: RealtimeServerEvent) async {
        switch event {
        case .sessionReady:
            resumeConfiguration()
            eventHandler?(.sessionReady)
        case .responseCreated:
            responseIsInFlight = true
            pauseMicrophoneAcceptanceForResponse()
        case .speechStarted:
            eventHandler?(.speechStarted)
        case .speechStopped:
            eventHandler?(.speechStopped)
        case .inputTranscriptDelta(let text):
            eventHandler?(.inputTranscriptDelta(text))
        case .inputTranscriptDone(let text):
            eventHandler?(.inputTranscriptDone(text))
        case .outputTranscriptDelta(let text):
            eventHandler?(.outputTranscriptDelta(text))
        case .outputTranscriptDone(let text):
            eventHandler?(.outputTranscriptDone(text))
        case .outputAudioStarted:
            outputAudioIsPlaying = true
            pauseMicrophoneAcceptanceForResponse()
            eventHandler?(.outputAudioStarted)
        case .outputAudioStopped:
            outputAudioIsPlaying = false
            eventHandler?(.outputAudioStopped)
            if !responseIsInFlight { scheduleMicrophoneResume() }
        case .outputAudioCleared:
            outputAudioIsPlaying = false
            eventHandler?(.outputAudioStopped)
            if !responseIsInFlight { scheduleMicrophoneResume() }
        case .functionCall(let name, let callID, let arguments):
            eventHandler?(.functionCall(name: name, callID: callID, arguments: arguments))
        case .responseDone:
            responseIsInFlight = false
            if !outputAudioIsPlaying { scheduleMicrophoneResume() }
            eventHandler?(.responseDone)
        case .error(let message):
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

    /// 응답 중에는 UI/턴 상태만 입력 불가로 유지한다. 로컬 WebRTC 트랙을 disable하면
    /// 일부 실기기에서 voice-processing AudioUnit의 녹음과 원격 playout이 함께
    /// 정지할 수 있으므로, 트랙은 연결 수명 동안 계속 살아 있게 둔다.
    private func pauseMicrophoneAcceptanceForResponse() {
        microphoneResumeTask?.cancel()
        microphoneResumeTask = nil
    }

    private func scheduleMicrophoneResume() {
        microphoneResumeTask?.cancel()
        microphoneResumeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.microphoneResumeDelay)
            } catch {
                return
            }
            guard let self,
                  self.isStarted,
                  !self.responseIsInFlight,
                  !self.outputAudioIsPlaying else { return }
            self.microphoneResumeTask = nil
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
