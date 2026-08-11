import Foundation

public struct RealtimeClientSecret: Decodable, Sendable, Equatable {
    public let value: String
    public let expiresAt: Int?

    enum CodingKeys: String, CodingKey {
        case value
        case expiresAt = "expires_at"
    }
}

public enum RealtimeClientError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case invalidEvent
    case alreadyConnected
    case notConnected
    case channelUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Realtime token response was invalid."
        case .httpStatus(let status): "Realtime token request failed with HTTP \(status)."
        case .invalidEvent: "Realtime event was invalid."
        case .alreadyConnected: "Realtime client is already connected."
        case .notConnected: "Realtime client is not connected."
        case .channelUnavailable: "Realtime WebRTC data channel is unavailable."
        }
    }
}

public struct RealtimeFunctionTool: Sendable, Equatable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public enum RealtimeServerEvent: Sendable, Equatable {
    case sessionReady
    case speechStarted
    case speechStopped
    case inputTranscriptDelta(String)
    case inputTranscriptDone(String)
    case outputTranscriptDelta(String)
    case outputTranscriptDone(String)
    case functionCall(name: String, callID: String, arguments: String)
    case responseDone
    case error(String)
    case ignored(String)

    public static func parse(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw RealtimeClientError.invalidEvent
        }

        switch type {
        case "session.updated":
            return .sessionReady
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "input_audio_buffer.speech_stopped":
            return .speechStopped
        case "conversation.item.input_audio_transcription.delta":
            return .inputTranscriptDelta(object["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .inputTranscriptDone(object["transcript"] as? String ?? "")
        case "response.output_audio_transcript.delta":
            return .outputTranscriptDelta(object["delta"] as? String ?? "")
        case "response.output_audio_transcript.done":
            return .outputTranscriptDone(object["transcript"] as? String ?? "")
        case "response.function_call_arguments.done":
            guard let name = object["name"] as? String,
                  let callID = object["call_id"] as? String else {
                throw RealtimeClientError.invalidEvent
            }
            return .functionCall(
                name: name,
                callID: callID,
                arguments: object["arguments"] as? String ?? "{}"
            )
        case "response.done":
            return .responseDone
        case "error":
            let error = object["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "Unknown Realtime error")
        default:
            return .ignored(type)
        }
    }
}

public enum RealtimeClientEvent {
    public static func sessionUpdate(
        instructions: String,
        tools: [RealtimeFunctionTool],
        transcriptionModel: String = "gpt-4o-transcribe",
        transcriptionLanguage: String = "ko"
    ) throws -> Data {
        let toolObjects: [[String: Any]] = tools.map {
            [
                "type": "function",
                "name": $0.name,
                "description": $0.description,
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ] as [String: Any],
            ]
        }
        return try encode([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": instructions,
                "tool_choice": "auto",
                "tools": toolObjects,
                "audio": [
                    "input": [
                        "transcription": [
                            "model": transcriptionModel,
                            "language": transcriptionLanguage,
                        ],
                        "turn_detection": [
                            "type": "semantic_vad",
                            "eagerness": "auto",
                            "create_response": true,
                            "interrupt_response": true,
                        ] as [String: Any],
                    ],
                ],
            ] as [String: Any],
        ])
    }

    public static func createResponse(instructions: String? = nil) throws -> Data {
        var response: [String: Any] = ["output_modalities": ["audio"]]
        if let instructions { response["instructions"] = instructions }
        return try encode(["type": "response.create", "response": response])
    }

    public static func functionOutput(callID: String, output: String) throws -> Data {
        try encode([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": output,
            ],
        ])
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
