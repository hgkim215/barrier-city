import Foundation
import DialogueKitOpenAI

enum RealtimeTransportOption: String, CaseIterable, Identifiable {
    case webSocket = "websocket"
    case webRTC = "webrtc"

    var id: Self { self }
    var title: String { self == .webSocket ? "WebSocket" : "WebRTC" }

    var kind: RealtimeTransportKind {
        self == .webSocket ? .webSocket : .webRTC
    }
}

/// 불안정할 수 있는 시뮬레이터 기능을 기본 동작과 분리한다.
enum DevelopmentOptions {
    static let simulatorMicrophoneKey = "development.simulatorMicrophoneEnabled"
    static let realtimeTransportKey = "development.realtimeTransport"

    static var simulatorMicrophoneEnabled: Bool {
#if targetEnvironment(simulator)
        UserDefaults.standard.bool(forKey: simulatorMicrophoneKey)
#else
        false
#endif
    }

    static var realtimeTransport: RealtimeTransportOption {
        let value = UserDefaults.standard.string(forKey: realtimeTransportKey)
        return RealtimeTransportOption(rawValue: value ?? "") ?? .webSocket
    }
}
