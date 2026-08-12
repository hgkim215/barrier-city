@preconcurrency import AVFoundation
import Foundation

private func realtimeAudioSessionLog(_ message: @autoclosure () -> String) {
#if DEBUG
    print("[Realtime][AudioSession] \(message())")
#endif
}

/// WebRTC의 네이티브 오디오 장치가 마이크와 출력을 소유하는 동안 앱의 다른 오디오와
/// AVAudioSession 변경이 충돌하지 않도록 기존 코디네이터에 수명주기를 등록한다.
@MainActor
final class RealtimeMediaTrackAudioSession {
    enum Error: LocalizedError {
        case simulatorUnavailable
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .simulatorUnavailable:
                "시뮬레이터 마이크 입력이 비활성화되어 있습니다."
            case .permissionDenied:
                "마이크 권한이 필요합니다."
            }
        }
    }

    private var hasAudioSessionClaim = false

    func start() async throws {
        realtimeAudioSessionLog("start requested")
#if targetEnvironment(simulator)
        realtimeAudioSessionLog(
            "running on simulator; Mac microphone option=\(DevelopmentOptions.simulatorMicrophoneEnabled)"
        )
        guard DevelopmentOptions.simulatorMicrophoneEnabled else {
            realtimeAudioSessionLog("blocked because simulator microphone option is off")
            throw Error.simulatorUnavailable
        }
#endif
        guard !hasAudioSessionClaim else {
            realtimeAudioSessionLog("audio session already acquired")
            return
        }
        let permissionGranted = await AVAudioApplication.requestRecordPermission()
        realtimeAudioSessionLog("record permission granted=\(permissionGranted)")
        guard permissionGranted else {
            throw Error.permissionDenied
        }
        try Task.checkCancellation()
        try AudioSessionCoordinator.shared.acquire(.realtimeConversation)
        hasAudioSessionClaim = true
        logCurrentRoute()
    }

    func stop() {
        guard hasAudioSessionClaim else {
            realtimeAudioSessionLog("stop skipped; audio session was not acquired")
            return
        }
        realtimeAudioSessionLog("releasing audio session")
        hasAudioSessionClaim = false
        AudioSessionCoordinator.shared.release(.realtimeConversation)
    }

    private func logCurrentRoute() {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map {
            "\($0.portType.rawValue):\($0.portName)"
        }
        let outputs = session.currentRoute.outputs.map {
            "\($0.portType.rawValue):\($0.portName)"
        }
        let availableInputs = session.availableInputs?.map {
            "\($0.portType.rawValue):\($0.portName)"
        } ?? []
        realtimeAudioSessionLog(
            "active category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
                + "sampleRate=\(session.sampleRate) inputChannels=\(session.inputNumberOfChannels) "
                + "routeInputs=\(inputs) routeOutputs=\(outputs) availableInputs=\(availableInputs)"
        )
    }
}
