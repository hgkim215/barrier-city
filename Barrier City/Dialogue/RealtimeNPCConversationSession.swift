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
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var eventHandler: (@MainActor (Event) -> Void)?
    private var currentOutputItem: (id: String, contentIndex: Int)?
    private var interruptedOutputItemID: String?

    func start(
        instructions: String,
        tools: [RealtimeFunctionTool],
        onEvent: @escaping @MainActor (Event) -> Void
    ) async throws {
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
                    // 정상 종료
                } catch {
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

            try await audio.start { chunk in
                audioStream.continuation.yield(chunk)
            }
            try await client.send(
                RealtimeClientEvent.sessionUpdate(
                    instructions: instructions,
                    tools: tools
                )
            )
            try await client.send(
                RealtimeClientEvent.createResponse(
                    instructions: "Greet the visitor naturally and briefly, then wait for their reply."
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
        audioContinuation?.finish()
        audioContinuation = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        audio.stop()
        if let client { await client.disconnect() }
        client = nil
        eventHandler = nil
        currentOutputItem = nil
        interruptedOutputItemID = nil
    }

    private func handle(_ event: RealtimeServerEvent) {
        switch event {
        case .sessionReady:
            eventHandler?(.sessionReady)
        case .speechStarted:
            let playedMilliseconds = audio.interruptOutput()
            interruptedOutputItemID = currentOutputItem?.id
            if let currentOutputItem, let playedMilliseconds, let client {
                Task { @MainActor [weak self] in
                    do {
                        try await client.send(
                            RealtimeClientEvent.truncateAudio(
                                itemID: currentOutputItem.id,
                                contentIndex: currentOutputItem.contentIndex,
                                audioEndMilliseconds: playedMilliseconds
                            )
                        )
                    } catch {
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
            eventHandler?(.failure(message))
        case .ignored:
            break
        }
    }
}
