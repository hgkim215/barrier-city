import SwiftUI

struct StartScreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var immersiveError: String?

    var body: some View {
        ZStack {
            Image("StartBackground")
                .resizable()
                .scaledToFill()
                .frame(width: 1208, height: 680)
                .offset(x: -4)

            Image("StartLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 488, height: 326)
                .position(x: 600, y: 270)
                .shadow(color: .white, radius: 10)

            startButton
                .position(x: 600, y: 540)

            if let immersiveError {
                Text(immersiveError)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.58), in: Capsule())
                    .position(x: 600, y: 625)
                    .accessibilityIdentifier("start-error-message")
            }
        }
        .frame(width: 1200, height: 680)
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .overlay(alignment: .topTrailing) {
            debugButton
                .padding(24)
        }
        .shadow(color: .black.opacity(0.25), radius: 20, x: 2, y: 4)
    }

    private var startButton: some View {
        Button {
            Task { @MainActor in
                await startExperience()
            }
        } label: {
            HStack(spacing: 10) {
                if model.immersiveSessionState.phase == .opening {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }

                Text(model.immersiveSessionState.phase == .opening ? "준비 중…" : "시작하기")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 2)
            }
            .frame(width: 240, height: 80)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.992, green: 0.851, blue: 0.173),
                             Color(red: 0.996, green: 0.584, blue: 0.039)],
                    startPoint: .top,
                    endPoint: .bottom),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.22), lineWidth: 2)
                    .padding(2)
            }
            .shadow(color: .black.opacity(0.25), radius: 10)
        }
        .buttonStyle(.plain)
        .disabled(model.immersiveSessionState.phase != .closed)
        .accessibilityLabel("휠체어 체험 시작")
        .accessibilityIdentifier("start-experience-button")
    }

    private var debugButton: some View {
        Button {
            openWindow(id: AppSceneID.debugControl, value: DebugWindowRoute.controlPanel)
        } label: {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("디버그 패널 열기")
        .accessibilityHint("별도 창으로 개발용 제어 패널을 엽니다")
        .accessibilityIdentifier("open-debug-panel-button")
    }

    @MainActor
    private func startExperience() async {
        guard let generation = model.beginImmersiveOpen() else { return }
        immersiveError = nil

        let event: StartExperienceEvent
        switch await openImmersiveSpace(id: AppSceneID.wheelchair) {
        case .opened:
            event = .immersiveOpened
        case .userCancelled:
            event = .immersiveOpenCancelled
        case .error:
            event = .immersiveOpenFailed
        @unknown default:
            event = .immersiveOpenFailed
        }

        let didComplete = model.completeImmersiveOpen(
            generation: generation,
            succeeded: event == .immersiveOpened)
        guard didComplete || event == .immersiveOpened else { return }

        let resolution = StartExperienceFlow.resolve(event)
        immersiveError = resolution.errorMessage
        if resolution.windowAction == .dismissStartWindow {
            dismissWindow(id: AppSceneID.start)
        }
    }
}

#Preview(windowStyle: .automatic) {
    StartScreenView()
        .environment(AppModel())
}
