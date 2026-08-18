import SwiftUI

/// 시작/종료 + 시뮬레이터용 디버그 입력 패널.
/// 시뮬레이터에는 손 추적이 없으므로 여기 슬라이더로 좌/우 바퀴를 민다.
struct ControlPanelView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var immersiveError: String?
    @State private var isCafeTransitioning = false
    @State private var isNPCConversationStarting = false
    @AppStorage(DevelopmentOptions.simulatorMicrophoneKey)
    private var simulatorMicrophoneEnabled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
            Text("휠체어 체험 시뮬레이터")
                .font(.title2).bold()

            // 전복(게임오버): 다시 시작 안내
            if model.motion.hasFallen {
                VStack(spacing: 12) {
                    Label("넘어졌습니다!", systemImage: "exclamationmark.triangle.fill")
                        .font(.title3).bold()
                        .foregroundStyle(.red)
                    Text("휠체어가 전복됐어요. 처음 위치에서 다시 시작합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        model.restart()
                    } label: {
                        Label("다시 시작하기", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(16)
                .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }

            Toggle("손 추적 사용(실기 Vision Pro)", isOn: handTrackingBinding)
                .toggleStyle(.switch)
                .fixedSize()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: testFistDriveBinding) {
                    HStack(spacing: 8) {
                        Label("테스트용 주먹 드론 조작", systemImage: "move.3d")
                        Spacer()
                        Text(model.testFistDriveEnabled ? "ON" : "OFF")
                            .font(.caption.bold())
                            .foregroundStyle(model.testFistDriveEnabled ? Color.green : Color.secondary)
                    }
                }
                .toggleStyle(.switch)

                Text("ON 후 손을 편 다음 주먹 쥐기(자동 중립) · 앞으로 밀면 전진 · 손을 좌우로 움직이면 회전 · 펴면 즉시 정지")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.testFistDriveEnabled {
                    Divider()

                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.fistDriveActive ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(model.handTrackingStatus)
                            .font(.caption)
                            .lineLimit(2)
                    }

                    HStack(spacing: 24) {
                        stat("전진 입력", String(format: "%.0f%%", model.fistDriveForwardAxis * 100))
                        stat("회전 입력", fistTurnLabel)
                        stat("조작 손", model.fistDriveHand.isEmpty ? "-" : model.fistDriveHand)
                    }
                    .font(.callout)
                }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            switch model.immersiveSessionState.phase {
            case .open, .closing:
                Button(role: .destructive) {
                    Task { @MainActor in
                        guard let generation = model.beginImmersiveClose() else { return }
                        await dismissSpace()
                        model.completeImmersiveClose(generation: generation)
                    }
                } label: {
                    Label(model.immersiveSessionState.controlTitle,
                          systemImage: "xmark.circle.fill")
                }
            case .closed, .opening:
                Button {
                    Task { @MainActor in
                        guard let generation = model.beginImmersiveOpen() else { return }
                        immersiveError = nil
                        switch await openSpace(id: "wheelchair") {
                        case .opened:
                            model.completeImmersiveOpen(generation: generation, succeeded: true)
                        case .userCancelled:
                            if model.completeImmersiveOpen(generation: generation, succeeded: false) {
                                immersiveError = "몰입 공간 열기가 취소되었습니다."
                            }
                        case .error:
                            if model.completeImmersiveOpen(generation: generation, succeeded: false) {
                                immersiveError = "몰입 공간을 열 수 없습니다. 잠시 후 다시 시도해 주세요."
                            }
                        @unknown default:
                            if model.completeImmersiveOpen(generation: generation, succeeded: false) {
                                immersiveError = "알 수 없는 이유로 몰입 공간을 열 수 없습니다."
                            }
                        }
                    }
                } label: {
                    Label(model.immersiveSessionState.controlTitle,
                          systemImage: "figure.roll")
                }
                .buttonStyle(.borderedProminent)
            }

            if let immersiveError {
                Text(immersiveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                openWindow(id: "npc-dialogue-test")
                Task { @MainActor in
                    await startNPCConversationForDevelopment()
                }
            } label: {
                Label(
                    isNPCConversationInProgress
                        ? "NPC 대화 내용 보기"
                        : (isNPCConversationStarting ? "NPC 대화 준비 중…" : "NPC와 대화 시작하기"),
                    systemImage: "person.wave.2.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

#if DEBUG
            Button {
                Task { @MainActor in
                    guard !isCafeTransitioning else { return }
                    isCafeTransitioning = true
                    immersiveError = nil
                    defer { isCafeTransitioning = false }
                    _ = await enterCafeForDevelopment()
                }
            } label: {
                Label(isCafeTransitioning ? "카페 준비 중…" : "개발: 카페 바로 시작",
                      systemImage: "cup.and.saucer.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

#if targetEnvironment(simulator)
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $simulatorMicrophoneEnabled) {
                    Label("개발: Mac 마이크로 NPC 대화", systemImage: "mic.fill")
                }
                .toggleStyle(.switch)
                .disabled(model.npcDialogue.isEncounterActive)

                Text("다음 대화부터 Realtime 음성을 사용합니다. visionOS Simulator의 오디오 입력 상태에 따라 동작하지 않거나 CoreAudio 경고가 발생할 수 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
#endif

            if model.isImmersive {
                VStack(spacing: 8) {
                    Text("NPC: \(model.npcClerk.phase.rawValue)"
                         + (model.npcClerk.lastPlayedAnimation.isEmpty
                            ? "" : " · \(model.npcClerk.lastPlayedAnimation)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        ForEach(NPCAnimationCue.allCases, id: \.rawValue) { cue in
                            Button(cue.rawValue) { model.npcClerk.playForTesting(cue) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
            }
#endif

            Divider()

            // 디버그 입력(손 추적 끈 경우)
            if !model.useHandTracking {
                VStack(alignment: .leading, spacing: 12) {
                    Text("디버그 입력 (시뮬레이터)")
                        .font(.headline)
                    Text("버튼을 누를 때마다 '한 번 밀기'입니다. 빠르게 여러 번 누르면 속도가 붙고, 멈추면 관성으로 굴러가다 마찰로 섭니다.")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button { model.pushLeft() }  label: { strokeLabel("왼쪽 밀기", "arrow.up.left") }
                        Button { model.pushBoth() }  label: { strokeLabel("양쪽 밀기(전진)", "arrow.up") }
                        Button { model.pushRight() } label: { strokeLabel("오른쪽 밀기", "arrow.up.right") }
                    }
                    .buttonStyle(.borderedProminent)

                    HStack(spacing: 10) {
                        Button("세게 양쪽 밀기") { model.pushBoth(1.0) }
                        Button(role: .cancel) { model.brake() } label: { Label("브레이크", systemImage: "hand.raised.fill") }
                    }
                    .buttonStyle(.bordered)
                    .font(.callout)

                    Text("좌/우를 번갈아 밀면 곡선 주행, 한쪽만 반복하면 제자리 회전에 가까워집니다.")
                        .font(.caption2).foregroundStyle(.secondary)

                    Divider()
                    JoystickControlView()
                }
            }

            Divider()

            // 상태 표시
            HStack(spacing: 24) {
                stat("속도", String(format: "%.2f m/s", model.motion.speed))
                stat("방향", String(format: "%.0f°", model.motion.headingDegrees))
                stat("FPS", String(format: "%.0f", model.motion.frameRate))
                stat("물리", String(format: "%.2f ms", model.motion.physicsUpdateMilliseconds))
                stat("누름", "\(model.pushCount)")
                stat("충격수신", "\(model.impulseApplied)")
            }
            .font(.callout)

            // 물리 진단(CharacterController)
            HStack(spacing: 24) {
                stat("콜리전", "\(model.motion.collisionShapeCount)")
                stat("레이/프레임", String(format: "%.1f", model.motion.raycastsPerFrame))
                stat("프레임", String(format: "%.1f ms", model.motion.frameTimeMilliseconds))
                stat("바닥Y", String(format: "%.2f", model.motion.groundHeight))
                stat("의자Y", String(format: "%.2f", model.motion.chairHeight))
                stat("pitch", String(format: "%.2f", model.motion.pitch))
                stat("막힘", model.motion.isBlocked ? "Y" : "N")
                stat("전복", model.motion.hasFallen ? "Y" : "N")
            }
            .font(.callout)

            // 손 추적 진단
            HStack(spacing: 24) {
                stat("손업데이트", "\(model.handUpdates)")
                stat("추적됨", "\(model.handTracked)")
                stat("골격", "\(model.handSkeletonOK)")
                stat("왼손쥠", String(format: "%.2f", model.leftGrabStrength))
                stat("오른손쥠", String(format: "%.2f", model.rightGrabStrength))
                stat("왼쪽거리", String(format: "%.2f", model.leftWheelDist))
                stat("오른쪽거리", String(format: "%.2f", model.rightWheelDist))
            }
                .font(.callout)

            HStack(spacing: 24) {
                stat("World", model.worldTrackingStatus)
                stat("추적 폴백", "\(model.worldTrackingFallbacks)")
            }
            .font(.callout)
            }
            .padding(28)
            .frame(width: 460)
        }
        .frame(width: 460, height: 720)
        .disabled(
            model.immersiveSessionState.isTransitioning
                || isCafeTransitioning
                || isNPCConversationStarting
        )
    }

    private func strokeLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ v: String) -> some View {
        VStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(v).monospacedDigit()
        }
    }

    /// 개발 패널에서 몰입 공간 생성과 실내 씬 전환을 한 번에 수행한다.
    /// `openImmersiveSpace` 반환 직후에는 RealityView의 worldRoot가 아직 준비 중일 수 있어
    /// 제한 시간 동안 기다린 뒤 기존 SceneSwitcher 경로를 그대로 호출한다.
    @MainActor
    private func enterCafeForDevelopment() async -> Bool {
        guard await openImmersiveSpaceIfNeeded() else { return false }

        for _ in 0..<100 where model.worldRoot == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.worldRoot != nil else {
            immersiveError = "몰입 공간은 열렸지만 카페 씬 준비가 지연되고 있습니다. 다시 눌러 주세요."
            return false
        }

        if InteractionModel.shared.scene == .outdoor {
            SceneSwitcher.requestIndoorTransition()
            for _ in 0..<100 where InteractionModel.shared.isTransitioning {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if InteractionModel.shared.scene != .indoor {
            immersiveError = InteractionModel.shared.transitionError
                ?? "카페 실내로 전환하지 못했습니다."
            return false
        }
        return true
    }

    /// 거리와 현재 퀘스트 진행도에 관계없이 개발 패널에서 실제 NPC 대화를 재현한다.
    /// 미션 상태는 공개된 정상 액션 순서로 세 번째 단계까지 맞춘 뒤, 점원 상태 머신의
    /// 개발 진입점만 호출하므로 Realtime 세션·자막·미션 이벤트 처리는 실플레이와 같다.
    @MainActor
    private func startNPCConversationForDevelopment() async {
        guard !isNPCConversationStarting else { return }
        if isNPCConversationInProgress { return }

        isNPCConversationStarting = true
        immersiveError = nil
        defer { isNPCConversationStarting = false }

        guard await enterCafeForDevelopment() else { return }

        let guide = GuideFlowModel.shared
        guide.reset()
        guide.skipOnboarding()
        guide.confirmMission()
        guide.handleQuestEvent(.enteredIndoor)
        guide.confirmMission()
        guide.handleQuestEvent(.kioskFailed)
        guide.confirmMission()

        guard guide.allowsNPCOrderConversation,
              model.npcClerk.startConversationForDevelopment() else {
            immersiveError = "NPC가 아직 준비되지 않았습니다. 잠시 후 다시 눌러 주세요."
            return
        }
    }

    private var isNPCConversationInProgress: Bool {
        if model.npcDialogue.isEncounterActive { return true }
        switch model.npcClerk.phase {
        case .greeting, .conversing:
            return true
        case .unavailable, .working, .orderAccepted:
            return false
        }
    }

    @MainActor
    private func openImmersiveSpaceIfNeeded() async -> Bool {
        // worldRoot는 RealityKit 장면의 구현 참조일 뿐 몰입 공간의 수명주기 상태가 아니다.
        // 종료 콜백보다 늦게 정리되거나 이전 장면 참조가 남아 있어도 재오픈을 막지 않는다.
        if model.isImmersive { return true }

        guard let generation = model.beginImmersiveOpen() else {
            return model.isImmersive
        }

        switch await openSpace(id: "wheelchair") {
        case .opened:
            model.completeImmersiveOpen(generation: generation, succeeded: true)
            return true
        case .userCancelled:
            if model.completeImmersiveOpen(generation: generation, succeeded: false) {
                immersiveError = "몰입 공간 열기가 취소되었습니다."
            }
        case .error:
            if model.completeImmersiveOpen(generation: generation, succeeded: false) {
                immersiveError = "몰입 공간을 열 수 없습니다. 잠시 후 다시 시도해 주세요."
            }
        @unknown default:
            if model.completeImmersiveOpen(generation: generation, succeeded: false) {
                immersiveError = "알 수 없는 이유로 몰입 공간을 열 수 없습니다."
            }
        }
        return false
    }

    private var handTrackingBinding: Binding<Bool> {
        Binding(
            get: { model.useHandTracking },
            set: { model.setHandTrackingEnabled($0) })
    }

    private var testFistDriveBinding: Binding<Bool> {
        Binding(
            get: { model.testFistDriveEnabled },
            set: { model.setTestFistDriveEnabled($0) })
    }

    private var fistTurnLabel: String {
        let turn = model.fistDriveTurnAxis
        guard abs(turn) >= 0.02 else { return "중앙" }
        let direction = turn < 0 ? "왼쪽" : "오른쪽"
        return "\(direction) \(String(format: "%.0f%%", abs(turn) * 100))"
    }
}
