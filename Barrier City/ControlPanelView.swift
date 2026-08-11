import SwiftUI
import DialogueKitOpenAI

/// 시작/종료 + 시뮬레이터용 디버그 입력 패널.
/// 시뮬레이터에는 손 추적이 없으므로 여기 슬라이더로 좌/우 바퀴를 민다.
struct ControlPanelView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var isImmersiveTransitioning = false
    @State private var immersiveError: String?
    @AppStorage(DevelopmentOptions.simulatorMicrophoneKey)
    private var simulatorMicrophoneEnabled = false
    @AppStorage(DevelopmentOptions.realtimeTransportKey)
    private var realtimeTransport = RealtimeTransportOption.webSocket.rawValue

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

            if model.isImmersive {
                Button(role: .destructive) {
                    Task { @MainActor in
                        guard !isImmersiveTransitioning else { return }
                        isImmersiveTransitioning = true
                        await dismissSpace()
                        isImmersiveTransitioning = false
                    }
                } label: {
                    Label("체험 종료", systemImage: "xmark.circle.fill")
                }
            } else {
                Button {
                    Task { @MainActor in
                        guard !isImmersiveTransitioning else { return }
                        isImmersiveTransitioning = true
                        immersiveError = nil
                        defer { isImmersiveTransitioning = false }
                        _ = await openImmersiveSpaceIfNeeded()
                    }
                } label: {
                    Label(isImmersiveTransitioning ? "여는 중…" : "체험 시작",
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
            } label: {
                Label("NPC와 대화 시작하기", systemImage: "person.wave.2.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

#if DEBUG
            VStack(alignment: .leading, spacing: 8) {
                Picker("Realtime 전송", selection: $realtimeTransport) {
                    ForEach(RealtimeTransportOption.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.npcDialogue.isEncounterActive)

                Text("다음 NPC 대화부터 적용됩니다. 동일 조건에서 각 전송을 번갈아 측정하세요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            Button {
                Task { @MainActor in
                    guard !isImmersiveTransitioning else { return }
                    isImmersiveTransitioning = true
                    immersiveError = nil
                    defer { isImmersiveTransitioning = false }
                    await enterCafeForDevelopment()
                }
            } label: {
                Label(isImmersiveTransitioning ? "카페 준비 중…" : "개발: 카페 바로 시작",
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

            if model.npcDialogue.realtimeMetrics.hasMeasurements {
                realtimeMetricsSection
            }

            if model.npcDialogue.realtimeABMetrics.hasMeasurements {
                realtimeABMetricsSection
            }

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
        .disabled(isImmersiveTransitioning)
    }

    private var realtimeMetricsSection: some View {
        let metrics = model.npcDialogue.realtimeMetrics
        return VStack(alignment: .leading, spacing: 8) {
            Label("Realtime 기준선", systemImage: "waveform.path.ecg")
                .font(.headline)

            HStack(spacing: 20) {
                stat("전송", metrics.transport.rawValue)
                stat("토큰", metricText(metrics.tokenMilliseconds))
                stat("연결", metricText(metrics.connectMilliseconds))
                stat("준비", metricText(metrics.readyMilliseconds))
            }
            HStack(spacing: 20) {
                stat("턴", metricText(metrics.lastTurnMilliseconds))
                stat("끼어들기", metricText(metrics.lastInterruptMilliseconds))
                stat("완료", "\(metrics.completedTurns)")
                stat("오류", "\(metrics.errorCount)")
            }
        }
        .font(.callout)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var realtimeABMetricsSection: some View {
        let comparison = model.npcDialogue.realtimeABMetrics
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Realtime A/B 누적", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                Button("초기화") {
                    model.npcDialogue.resetRealtimeABMetrics()
                }
                .font(.caption)
                .disabled(model.npcDialogue.isEncounterActive)
            }

            transportAggregateRow("WebSocket", comparison.webSocket)
            Divider()
            transportAggregateRow("WebRTC", comparison.webRTC)
        }
        .font(.callout)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func transportAggregateRow(
        _ name: String,
        _ aggregate: RealtimeTransportAggregate
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(name) · \(aggregate.sessionCount) 세션")
                .font(.caption.bold())
            HStack(spacing: 14) {
                stat("연결 평균", metricText(aggregate.averageConnectMilliseconds))
                stat("준비 평균", metricText(aggregate.averageReadyMilliseconds))
                stat("턴 평균/p95", metricPair(
                    aggregate.averageTurnMilliseconds,
                    aggregate.p95TurnMilliseconds
                ))
            }
            HStack(spacing: 14) {
                stat("끼어들기 평균/p95", metricPair(
                    aggregate.averageInterruptionMilliseconds,
                    aggregate.p95InterruptionMilliseconds
                ))
                stat("턴 표본", "\(aggregate.turnSamples.count)")
                stat("오류", "\(aggregate.errorCount)")
            }
        }
    }

    private func metricText(_ milliseconds: Int?) -> String {
        milliseconds.map { "\($0) ms" } ?? "-"
    }

    private func metricPair(_ average: Int?, _ p95: Int?) -> String {
        guard let average, let p95 else { return "-" }
        return "\(average)/\(p95) ms"
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
    private func enterCafeForDevelopment() async {
        guard await openImmersiveSpaceIfNeeded() else { return }

        for _ in 0..<100 where model.worldRoot == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.worldRoot != nil else {
            immersiveError = "몰입 공간은 열렸지만 카페 씬 준비가 지연되고 있습니다. 다시 눌러 주세요."
            return
        }

        if InteractionModel.shared.scene == .outdoor {
            await SceneSwitcher.switchToIndoor()
        }
        if InteractionModel.shared.scene != .indoor {
            immersiveError = InteractionModel.shared.transitionError
                ?? "카페 실내로 전환하지 못했습니다."
        }
    }

    @MainActor
    private func openImmersiveSpaceIfNeeded() async -> Bool {
        // worldRoot는 RealityKit 장면의 구현 참조일 뿐 몰입 공간의 수명주기 상태가 아니다.
        // 종료 콜백보다 늦게 정리되거나 이전 장면 참조가 남아 있어도 재오픈을 막지 않는다.
        if model.isImmersive { return true }

        switch await openSpace(id: "wheelchair") {
        case .opened:
            return true
        case .userCancelled:
            immersiveError = "몰입 공간 열기가 취소되었습니다."
        case .error:
            immersiveError = "몰입 공간을 열 수 없습니다. 잠시 후 다시 시도해 주세요."
        @unknown default:
            immersiveError = "알 수 없는 이유로 몰입 공간을 열 수 없습니다."
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
