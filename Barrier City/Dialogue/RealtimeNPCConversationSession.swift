//
//  RealtimeNPCConversationSession.swift
//  Barrier City
//
//  WebSocket, 마이크, 스트리밍 재생의 수명주기를 NPC UI 상태와 분리한다.
//

import Foundation
import DialogueKitOpenAI

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

    private let audio = RealtimeAudioIO()
    private var client: RealtimeWebSocketClient?
    private var receiveTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var configurationSendTask: Task<Void, Never>?
    private var truncateTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var eventHandler: (@MainActor (Event) -> Void)?
    private var sessionConfigurationContinuation: CheckedContinuation<Void, Error>?
    private var currentOutputItem: (id: String, contentIndex: Int)?
    private var interruptedOutputItemID: String?

    func start(
        instructions: String,
        tools: [RealtimeFunctionTool],
        onEvent: @escaping @MainActor (Event) -> Void
    ) async throws {
        guard client == nil else { throw RealtimeClientError.alreadyConnected }
        try Task.checkCancellation()
        let client = RealtimeWebSocketClient(config: AppConfig.proxy)
        self.client = client
        eventHandler = onEvent

        let audioStream = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        audioContinuation = audioStream.continuation

        do {
            try await client.connect()

            receiveTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await event in client.events {
                        self.handle(event)
                    }
                } catch is CancellationError {
                    self.resumeSessionConfiguration(throwing: CancellationError())
                } catch {
                    self.resumeSessionConfiguration(throwing: error)
                    self.eventHandler?(.failure(error.localizedDescription))
                }
            }

            audioSendTask = Task { @MainActor [weak self] in
                do {
                    for await chunk in audioStream.stream {
                        guard !Task.isCancelled else { return }
                        try await client.send(RealtimeClientEvent.appendAudio(chunk))
                    }
                } catch is CancellationError {
                    // 정상 종료
                } catch {
                    self?.eventHandler?(.failure(error.localizedDescription))
                }
            }

            try await configureSession(
                client,
                instructions: instructions,
                tools: tools
            )
            try Task.checkCancellation()
            try await audio.start { chunk in
                audioStream.continuation.yield(chunk)
            }
            try Task.checkCancellation()
            try await client.send(
                RealtimeClientEvent.createResponse(
                    instructions: """
                    Respond ONLY in Korean. Briefly greet the visitor in natural spoken Korean,
                    then stop and wait for their reply. Do not use any English words.
                    """
                )
            )
        } catch {
            await stop()
            throw error
        }
    }

    func completeFunctionCall(callID: String, output: String) async throws {
        guard let client else { throw RealtimeClientError.notConnected }
        try await client.send(
            RealtimeClientEvent.functionOutput(callID: callID, output: output)
        )
        try await client.send(RealtimeClientEvent.createResponse())
    }

    func stop() async {
        resumeSessionConfiguration(throwing: CancellationError())
        eventHandler = nil
        audioContinuation?.finish()
        audioContinuation = nil
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
        sendTask?.cancel()
        eventTask?.cancel()
        audio.stop()
        if let client { await client.disconnect() }
        client = nil
        await configurationTask?.value
        await pendingTruncateTask?.value
        await sendTask?.value
        await eventTask?.value
        currentOutputItem = nil
        interruptedOutputItemID = nil
    }

    private func handle(_ event: RealtimeServerEvent) {
        switch event {
        case .sessionCreated:
            break
        case .sessionReady:
            resumeSessionConfiguration()
            eventHandler?(.sessionReady)
        case .speechStarted:
            let playedMilliseconds = audio.interruptOutput()
            interruptedOutputItemID = currentOutputItem?.id
            if let currentOutputItem, let playedMilliseconds, let client {
                truncateTask?.cancel()
                truncateTask = Task { @MainActor [weak self] in
                    do {
                        try await client.send(
                            RealtimeClientEvent.truncateAudio(
                                itemID: currentOutputItem.id,
                                contentIndex: currentOutputItem.contentIndex,
                                audioEndMilliseconds: playedMilliseconds
                            )
                        )
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.eventHandler?(.failure(error.localizedDescription))
                    }
                }
            }
            currentOutputItem = nil
            eventHandler?(.speechStarted)
        case .speechStopped:
            eventHandler?(.speechStopped)
        case .inputTranscriptDelta(let text):
            eventHandler?(.inputTranscriptDelta(text))
        case .inputTranscriptDone(let text):
            eventHandler?(.inputTranscriptDone(text))
        case .outputAudio(let itemID, let contentIndex, let data):
            guard itemID != interruptedOutputItemID else { return }
            interruptedOutputItemID = nil
            let beginsResponse = currentOutputItem?.id != itemID
                || currentOutputItem?.contentIndex != contentIndex
            currentOutputItem = (itemID, contentIndex)
            audio.enqueueOutput(data, beginsResponse: beginsResponse)
        case .outputTranscriptDelta(let text):
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
            eventHandler?(.failure(message))
        case .ignored:
            break
        }
    }

    private func configureSession(
        _ client: RealtimeWebSocketClient,
        instructions: String,
        tools: [RealtimeFunctionTool]
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sessionConfigurationContinuation = continuation
                configurationSendTask?.cancel()
                configurationSendTask = Task { @MainActor [weak self] in
                    do {
                        try await client.send(
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
