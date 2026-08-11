//
//  RealtimeNPCConversationSession.swift
//  Barrier City
//
//  Realtime 전송, 마이크, 스트리밍 재생의 수명주기를 NPC UI 상태와 분리한다.
//

import Foundation
import DialogueKitOpenAI
import OSLog

@MainActor
final class RealtimeNPCConversationSession {
    typealias TransportFactory = @MainActor () -> any RealtimeTransport

    enum Event: Sendable {
        case sessionReady
        case inputLevel(Float)
        case speechStarted
        case speechStopped
        case inputTranscriptDelta(String)
        case inputTranscriptDone(String)
        case outputTranscriptDelta(String)
        case outputTranscriptDone(String)
        case functionCall(name: String, callID: String, arguments: String)
        case responseDone
        case diagnostics(RealtimeMetricsSnapshot)
        case failure(String)
    }

    private static let diagnosticsLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BarrierCity",
        category: "RealtimeMetrics"
    )

    private let audio = RealtimeAudioIO()
    private let mediaTrackAudioSession = RealtimeMediaTrackAudioSession()
    private let makeTransport: TransportFactory
    private var diagnostics = RealtimeMetricsRecorder(transport: .webSocket)
    private var transport: (any RealtimeTransport)?
    private var receiveTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var configurationSendTask: Task<Void, Never>?
    private var truncateTask: Task<Void, Never>?
    private var inputLevelTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var inputLevelContinuation: AsyncStream<Float>.Continuation?
    private var eventHandler: (@MainActor (Event) -> Void)?
    private var sessionConfigurationContinuation: CheckedContinuation<Void, Error>?
    private var currentOutputItem: (id: String, contentIndex: Int)?
    private var interruptedOutputItemID: String?
    private var isOutputActive = false

    init(
        makeTransport: @escaping TransportFactory = {
            RealtimeWebSocketClient(config: AppConfig.proxy)
        }
    ) {
        self.makeTransport = makeTransport
    }

    func start(
        instructions: String,
        tools: [RealtimeFunctionTool],
        onEvent: @escaping @MainActor (Event) -> Void
    ) async throws {
        guard transport == nil else { throw RealtimeClientError.alreadyConnected }
        try Task.checkCancellation()
        let transport = makeTransport()
        let usesEventAudio = transport.audioDelivery == .events
        diagnostics = RealtimeMetricsRecorder(transport: transport.kind)
        diagnostics.beginSession()
        self.transport = transport
        eventHandler = onEvent

        do {
            if !usesEventAudio {
                try await mediaTrackAudioSession.start()
            }
            try await transport.connect()
            if let tokenMilliseconds = await transport.lastTokenRequestMilliseconds {
                diagnostics.recordToken(milliseconds: tokenMilliseconds)
                publishDiagnostics()
            }

            receiveTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await event in transport.events {
                        self.handle(event)
                    }
                } catch is CancellationError {
                    self.resumeSessionConfiguration(throwing: CancellationError())
                } catch {
                    self.resumeSessionConfiguration(throwing: error)
                    self.reportFailure(error.localizedDescription)
                }
            }

            if usesEventAudio {
                let audioStream = AsyncStream.makeStream(
                    of: Data.self,
                    bufferingPolicy: .bufferingNewest(64)
                )
                audioContinuation = audioStream.continuation
                let inputLevelStream = AsyncStream.makeStream(
                    of: Float.self,
                    bufferingPolicy: .bufferingNewest(1)
                )
                inputLevelContinuation = inputLevelStream.continuation

                audioSendTask = Task { @MainActor [weak self] in
                    do {
                        for await chunk in audioStream.stream {
                            guard !Task.isCancelled else { return }
                            try await transport.send(RealtimeClientEvent.appendAudio(chunk))
                        }
                    } catch is CancellationError {
                        // 정상 종료
                    } catch {
                        self?.reportFailure(error.localizedDescription)
                    }
                }

                inputLevelTask = Task { @MainActor [weak self] in
                    for await level in inputLevelStream.stream {
                        guard !Task.isCancelled else { return }
                        self?.handleInputLevel(level)
                    }
                }
            }

            try await configureSession(
                transport,
                instructions: instructions,
                tools: tools
            )
            try Task.checkCancellation()
            if usesEventAudio,
               let audioContinuation,
               let inputLevelContinuation {
                try await audio.start(
                    onInput: { chunk in audioContinuation.yield(chunk) },
                    onInputLevel: { level in inputLevelContinuation.yield(level) }
                )
            }
            try Task.checkCancellation()
            try await transport.send(
                RealtimeClientEvent.createResponse(
                    instructions: """
                    Respond ONLY in Korean. Briefly greet the visitor in natural spoken Korean,
                    then stop and wait for their reply. Do not use any English words.
                    """
                )
            )
        } catch {
            if diagnostics.snapshot.errorCount == 0 {
                reportFailure(error.localizedDescription)
            }
            await stop()
            throw error
        }
    }

    func completeFunctionCall(callID: String, output: String) async throws {
        guard let transport else { throw RealtimeClientError.notConnected }
        try await transport.send(
            RealtimeClientEvent.functionOutput(callID: callID, output: output)
        )
        try await transport.send(RealtimeClientEvent.createResponse())
    }

    func stop() async {
        resumeSessionConfiguration(throwing: CancellationError())
        eventHandler = nil
        audioContinuation?.finish()
        audioContinuation = nil
        inputLevelContinuation?.finish()
        inputLevelContinuation = nil
        let configurationTask = configurationSendTask
        configurationSendTask = nil
        let pendingTruncateTask = truncateTask
        truncateTask = nil
        configurationTask?.cancel()
        pendingTruncateTask?.cancel()
        let sendTask = audioSendTask
        audioSendTask = nil
        let eventTask = receiveTask
        receiveTask = nil
        let levelTask = inputLevelTask
        inputLevelTask = nil
        sendTask?.cancel()
        eventTask?.cancel()
        levelTask?.cancel()
        audio.stop()
        mediaTrackAudioSession.stop()
        if let transport { await transport.disconnect() }
        transport = nil
        await configurationTask?.value
        await pendingTruncateTask?.value
        await sendTask?.value
        await eventTask?.value
        await levelTask?.value
        currentOutputItem = nil
        interruptedOutputItemID = nil
        isOutputActive = false
        diagnostics.cancelPendingInterruption()
    }

    private func handle(_ event: RealtimeServerEvent) {
        switch event {
        case .sessionCreated:
            diagnostics.recordSessionCreated()
            publishDiagnostics()
        case .sessionReady:
            diagnostics.recordSessionReady()
            publishDiagnostics()
            resumeSessionConfiguration()
            eventHandler?(.sessionReady)
        case .speechStarted:
            let usesEventAudio = transport?.audioDelivery == .events
            let playedMilliseconds = usesEventAudio ? audio.interruptOutput() : nil
            if usesEventAudio {
                isOutputActive = false
                if diagnostics.recordInterruptionCompleted() {
                    publishDiagnostics()
                }
            } else if isOutputActive {
                diagnostics.recordLocalInterruptionStart()
            }
            interruptedOutputItemID = currentOutputItem?.id
            if usesEventAudio,
               let currentOutputItem,
               let playedMilliseconds,
               let transport {
                truncateTask?.cancel()
                truncateTask = Task { @MainActor [weak self] in
                    do {
                        try await transport.send(
                            RealtimeClientEvent.truncateAudio(
                                itemID: currentOutputItem.id,
                                contentIndex: currentOutputItem.contentIndex,
                                audioEndMilliseconds: playedMilliseconds
                            )
                        )
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.reportFailure(error.localizedDescription)
                    }
                }
            }
            currentOutputItem = nil
            eventHandler?(.speechStarted)
        case .speechStopped:
            diagnostics.recordSpeechStopped()
            eventHandler?(.speechStopped)
        case .inputTranscriptDelta(let text):
            eventHandler?(.inputTranscriptDelta(text))
        case .inputTranscriptDone(let text):
            eventHandler?(.inputTranscriptDone(text))
        case .outputAudioBufferStarted:
            isOutputActive = true
            recordFirstOutputIfNeeded()
        case .outputAudioBufferCleared:
            isOutputActive = false
            if diagnostics.recordInterruptionCompleted() {
                publishDiagnostics()
            }
        case .outputAudioBufferStopped:
            isOutputActive = false
        case .outputAudio(let itemID, let contentIndex, let data):
            guard transport?.audioDelivery == .events else { return }
            guard itemID != interruptedOutputItemID else { return }
            interruptedOutputItemID = nil
            isOutputActive = true
            recordFirstOutputIfNeeded()
            let beginsResponse = currentOutputItem?.id != itemID
                || currentOutputItem?.contentIndex != contentIndex
            currentOutputItem = (itemID, contentIndex)
            audio.enqueueOutput(data, beginsResponse: beginsResponse)
        case .outputTranscriptDelta(let text):
            recordFirstOutputIfNeeded()
            eventHandler?(.outputTranscriptDelta(text))
        case .outputTranscriptDone(let text):
            eventHandler?(.outputTranscriptDone(text))
        case .functionCall(let name, let callID, let arguments):
            eventHandler?(.functionCall(name: name, callID: callID, arguments: arguments))
        case .responseDone:
            eventHandler?(.responseDone)
        case .error(let message):
            resumeSessionConfiguration(
                throwing: NSError(
                    domain: "OpenAI.Realtime",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            )
            reportFailure(message)
        case .ignored:
            break
        }
    }

    private func handleInputLevel(_ level: Float) {
        if isOutputActive, level >= 0.28 {
            diagnostics.recordLocalInterruptionStart()
        }
        eventHandler?(.inputLevel(level))
    }

    private func recordFirstOutputIfNeeded() {
        if diagnostics.recordFirstOutput() {
            publishDiagnostics()
        }
    }

    private func reportFailure(_ message: String) {
        diagnostics.recordError()
        publishDiagnostics()
        eventHandler?(.failure(message))
    }

    private func publishDiagnostics() {
        let snapshot = diagnostics.snapshot
        Self.diagnosticsLogger.info(
            "transport=\(snapshot.transport.rawValue, privacy: .public) token_ms=\(snapshot.tokenMilliseconds ?? -1, privacy: .public) connect_ms=\(snapshot.connectMilliseconds ?? -1, privacy: .public) ready_ms=\(snapshot.readyMilliseconds ?? -1, privacy: .public) turn_ms=\(snapshot.lastTurnMilliseconds ?? -1, privacy: .public) interrupt_ms=\(snapshot.lastInterruptMilliseconds ?? -1, privacy: .public) errors=\(snapshot.errorCount, privacy: .public)"
        )
        eventHandler?(.diagnostics(snapshot))
    }

    private func configureSession(
        _ transport: any RealtimeTransport,
        instructions: String,
        tools: [RealtimeFunctionTool]
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sessionConfigurationContinuation = continuation
                configurationSendTask?.cancel()
                configurationSendTask = Task { @MainActor [weak self] in
                    do {
                        try await transport.send(
                            RealtimeClientEvent.sessionUpdate(
                                instructions: instructions,
                                tools: tools
                            )
                        )
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.resumeSessionConfiguration(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeSessionConfiguration(throwing: CancellationError())
            }
        }
    }

    private func resumeSessionConfiguration(throwing error: Error? = nil) {
        guard let continuation = sessionConfigurationContinuation else { return }
        sessionConfigurationContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
