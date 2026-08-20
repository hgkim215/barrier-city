import RealityKit
import Foundation

/// 카페 실내 배경음악. AVAudioPlayer로 그냥 틀면 헤드폰으로 듣는 것처럼 머리에 딱
/// 붙어 들린다. 대신 RealityKit의 AmbientAudioComponent로 worldRoot(카페 공간) 안에
/// 재생해, 공간 전체를 채우는 느낌과 공간 리버브가 자연스럽게 실린다.
///
/// Indoor 진입 시 시작해 무한 반복하고, Outdoor로 돌아가거나 몰입 공간이 닫히면 멈춘다.
@MainActor
final class BackgroundMusicController {
    static let shared = BackgroundMusicController()

    private enum Tuning {
        /// 효과음/NPC 대화보다 은은하게 깔리는 목표 볼륨.
        static let targetGain: Audio.Decibel = -12
        static let fadeInDuration: TimeInterval = 1.5
    }

    private var audioEntity: Entity?
    private var playback: AudioPlaybackController?
    private var loadTask: Task<Void, Never>?

    private init() {}

    /// Indoor 진입 시 호출. worldRoot 아래에 앰비언트 오디오 엔티티를 만들어 재생한다.
    func startIndoorLoop(worldRoot: Entity) {
        guard audioEntity == nil, loadTask == nil else { return }
        guard let url = Bundle.main.url(forResource: "background_music_indoor", withExtension: "mp3") else { return }

        let entity = Entity()
        entity.name = "IndoorBackgroundMusic"
        entity.components.set(AmbientAudioComponent())
        worldRoot.addChild(entity)
        audioEntity = entity

        loadTask = Task { [weak self] in
            let resource = try? await AudioFileResource(
                contentsOf: url,
                configuration: .init(shouldLoop: true))
            guard let self, let resource, self.audioEntity === entity else { return }
            let controller = entity.playAudio(resource)
            controller.gain = -60
            controller.fade(to: Tuning.targetGain, duration: Tuning.fadeInDuration)
            self.playback = controller
            self.loadTask = nil
        }
    }

    /// Outdoor로 돌아가거나(향후 실내→실외 전환 추가 시) 몰입 공간이 닫힐 때 호출.
    func stopIndoorLoop() {
        loadTask?.cancel()
        loadTask = nil
        playback?.stop()
        playback = nil
        audioEntity?.removeFromParent()
        audioEntity = nil
    }
}
