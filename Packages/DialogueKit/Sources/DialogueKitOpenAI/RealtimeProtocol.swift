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
    public let parameters: [RealtimeFunctionParameter]

    public init(
        name: String,
        description: String,
        parameters: [RealtimeFunctionParameter] = []
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct RealtimeFunctionParameter: Sendable, Equatable {
    public enum ValueType: String, Sendable {
        case string
        case integer
    }

    public let name: String
    public let type: ValueType
    public let description: String
    public let isRequired: Bool
    public let allowedStringValues: [String]?
    public let minimumIntegerValue: Int?
    public let maximumIntegerValue: Int?

    public init(
        name: String,
        type: ValueType,
        description: String,
        isRequired: Bool = true,
        allowedStringValues: [String]? = nil,
        minimumIntegerValue: Int? = nil,
        maximumIntegerValue: Int? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.allowedStringValues = allowedStringValues
        self.minimumIntegerValue = minimumIntegerValue
        self.maximumIntegerValue = maximumIntegerValue
    }
}

public enum RealtimeServerEvent: Sendable, Equatable {
    case sessionReady
    case responseCreated
    case speechStarted
    case speechStopped
    case inputTranscriptDelta(String)
    case inputTranscriptDone(String)
    case outputTranscriptDelta(String)
    case outputTranscriptDone(String)
    case outputAudioStarted
    case outputAudioStopped
    case outputAudioCleared
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
        case "response.created":
            return .responseCreated
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
        case "output_audio_buffer.started":
            return .outputAudioStarted
        case "output_audio_buffer.stopped":
            return .outputAudioStopped
        case "output_audio_buffer.cleared":
            return .outputAudioCleared
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
        let toolObjects: [[String: Any]] = tools.map { tool in
            let properties = Dictionary(uniqueKeysWithValues: tool.parameters.map { parameter in
                var schema: [String: Any] = [
                    "type": parameter.type.rawValue,
                    "description": parameter.description,
                ]
                if let allowedValues = parameter.allowedStringValues {
                    schema["enum"] = allowedValues
                }
                if let minimum = parameter.minimumIntegerValue {
                    schema["minimum"] = minimum
                }
                if let maximum = parameter.maximumIntegerValue {
                    schema["maximum"] = maximum
                }
                return (parameter.name, schema)
            })
            let required = tool.parameters.filter(\.isRequired).map(\.name)
            return [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
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
                        // VAD는 발화 구간만 나누고, transcript 확인 뒤 앱이 응답을 요청한다.
                        // 이 방식이면 NPC 출력 중 감지된 에코가 새 응답을 자동 생성하지 않는다.
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": NSDecimalNumber(string: "0.65"),
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 700,
                            "create_response": false,
                            "interrupt_response": false,
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
