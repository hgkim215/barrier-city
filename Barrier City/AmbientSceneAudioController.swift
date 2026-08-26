import RealityKit
import Foundation
import OSLog

/// 현재 배경(실외/실내)의 환경음 한 트랙을 재생한다. AVAudioPlayer로 그냥 틀면
/// 헤드폰으로 듣는 것처럼 머리에 딱 붙어 들린다. 대신 RealityKit의
/// AmbientAudioComponent로 worldRoot(사용자가 있는 공간) 안에 재생해, 공간 전체를
/// 채우는 느낌과 환경 리버브가 자연스럽게 실린다.
///
/// 실외/실내는 동시에 존재하지 않는 배타적 상태라 트랙 슬롯 하나로 관리한다.
/// 다른 트랙으로 play()를 호출하면 재생 중이던 트랙을 먼저 정리하고 새로 시작한다.
@MainActor
final class AmbientSceneAudioController {
    static let shared = AmbientSceneAudioController()

    private enum Tuning {
        static let targetGain: Audio.Decibel = -12
        static let silentGain: Audio.Decibel = -60
        static let fadeInDuration: TimeInterval = 1.5
        /// 트랙 전환 시 이전 트랙을 하드컷하지 않고 짧게 줄이는 데 쓰는 시간.
        static let fadeOutDuration: TimeInterval = 0.35
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BarrierCity",
        category: "AmbientSceneAudioController")

    private var currentResourceName: String?
    private var audioEntity: Entity?
    private var playback: AudioPlaybackController?
    private var loadTask: Task<Void, Never>?
    private var hasAudioSessionClaim = false

    private init() {}

    /// 몰입 공간이 열릴 때(Outdoor) 또는 Indoor로 전환될 때 호출.
    /// 이미 같은 트랙이 재생 중이면 아무 것도 하지 않고, 다른 트랙이 재생 중이었다면
    /// 먼저 멈춘 뒤 새로 시작한다.
    func play(resource resourceName: String, worldRoot: Entity) {
        guard currentResourceName != resourceName else { return }
        stopTrack()
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp3") else {
            Self.logger.error("배경음 리소스 없음: \(resourceName, privacy: .public).mp3 (번들에 포함되지 않음)")
            return
        }
        currentResourceName = resourceName

        if !hasAudioSessionClaim {
            do {
                try AudioSessionCoordinator.shared.acquire(.playback)
                hasAudioSessionClaim = true
            } catch {
                Self.logger.error("오디오 세션 확보 실패(\(resourceName, privacy: .public)): \(String(describing: error), privacy: .public)")
                return
            }
        }

        let entity = Entity()
        entity.name = "AmbientSceneAudio(\(resourceName))"
        entity.components.set(AmbientAudioComponent())
        worldRoot.addChild(entity)
        audioEntity = entity

        loadTask = Task { [weak self] in
            let resource: AudioFileResource
            do {
                resource = try await AudioFileResource(
                    contentsOf: url,
                    configuration: .init(shouldLoop: true))
            } catch {
                Self.logger.error("배경음 로드 실패(\(resourceName, privacy: .public)): \(String(describing: error), privacy: .public)")
                return
            }
            guard let self, self.audioEntity === entity else {
                Self.logger.error("배경음 재생 취소: 로드 중 트랙이 교체됨(\(resourceName, privacy: .public))")
                return
            }
            let controller = entity.playAudio(resource)
            controller.gain = -60
            controller.fade(to: Tuning.targetGain, duration: Tuning.fadeInDuration)
            self.playback = controller
            self.loadTask = nil
            Self.logger.info("배경음 재생 시작: \(resourceName, privacy: .public)")
        }
    }

    /// 씬을 벗어나거나(향후 실내→실외 전환 추가 시) 몰입 공간이 닫힐 때 호출.
    func stop() {
        stopTrack()
        guard hasAudioSessionClaim else { return }
        hasAudioSessionClaim = false
        AudioSessionCoordinator.shared.release(.playback)
    }

    /// 트랙만 정리한다. 세션 사용권은 유지해 outdoor→indoor처럼 같은 프레임 안에서
    /// 트랙만 바뀌는 경우 세션을 불필요하게 반납했다 다시 잡지 않게 한다.
    ///
    /// 재생 중인 파형을 그 자리에서 뚝 끊지 않고 짧게 페이드아웃한 뒤 정리한다 —
    /// 하드컷은 실외→실내처럼 트랙이 바뀌는 바로 그 순간 "딱" 하는 클릭음을
    /// 내는데, 이 앱의 다른 효과음도 전부 저음 충격음이라 유저에게는 씬이 새로
    /// 로딩되며 충돌한 것처럼 들렸다.
    private func stopTrack() {
        currentResourceName = nil
        loadTask?.cancel()
        loadTask = nil
        if let playback, let audioEntity {
            playback.fade(to: Tuning.silentGain, duration: Tuning.fadeOutDuration)
            Task { [playback, audioEntity] in
                try? await Task.sleep(for: .seconds(Tuning.fadeOutDuration))
                playback.stop()
                audioEntity.removeFromParent()
            }
        }
        playback = nil
        audioEntity = nil
    }
}
