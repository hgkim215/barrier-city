import AVKit
import Observation
import SwiftUI

@Observable @MainActor
private final class LoopingGuidePlayback {
    let player: AVQueuePlayer
    private let looper: AVPlayerLooper

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
    }

    func play() { player.play() }

    func stop() {
        player.pause()
        player.removeAllItems()
    }
}

struct LoopingGuideVideoView: View {
    let resourceName: String
    let placeholderResourceName: String?
    @State private var playback: LoopingGuidePlayback?

    init(
        resourceName: String,
        placeholderResourceName: String? = "onboarding-placeholder"
    ) {
        self.resourceName = resourceName
        self.placeholderResourceName = placeholderResourceName
    }

    var body: some View {
        Group {
            if let playback {
                VideoPlayer(player: playback.player)
                    .allowsHitTesting(false)
            } else {
                ContentUnavailableView(
                    "영상 준비 중",
                    systemImage: "video.slash",
                    description: Text("조작 가이드 영상이 준비되면 자동으로 표시됩니다."))
            }
        }
        .background(.black.opacity(0.35))
        .clipShape(.rect(cornerRadius: 20))
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: resourceName) { _, _ in
            stop()
            start()
        }
    }

    private func start() {
        let placeholderURL = placeholderResourceName.flatMap {
            Bundle.main.url(forResource: $0, withExtension: "mp4")
        }
        let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4")
            ?? placeholderURL
        guard let url else { return }
        let next = LoopingGuidePlayback(url: url)
        playback = next
        next.play()
    }

    private func stop() {
        playback?.stop()
        playback = nil
    }
}
