import SwiftUI

/// 시작/종료 + 시뮬레이터용 디버그 입력 패널.
/// 시뮬레이터에는 손 추적이 없으므로 여기 슬라이더로 좌/우 바퀴를 민다.
struct ControlPanelView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var isImmersiveTransitioning = false
    @State private var immersiveError: String?

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 20) {
            Text("휠체어 체험 시뮬레이터")
                .font(.title2).bold()

            // 전복(게임오버): 다시 시작 안내
            if model.fallen {
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

            Toggle("손 추적 사용(실기 Vision Pro)", isOn: $model.useHandTracking)
                .toggleStyle(.switch)
                .fixedSize()

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

                        switch await openSpace(id: "wheelchair") {
                        case .opened:
                            break
                        case .userCancelled:
                            immersiveError = "몰입 공간 열기가 취소되었습니다."
                        case .error:
                            immersiveError = "몰입 공간을 열 수 없습니다. 잠시 후 다시 시도해 주세요."
                        @unknown default:
                            immersiveError = "알 수 없는 이유로 몰입 공간을 열 수 없습니다."
                        }
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
                stat("속도", String(format: "%.2f m/s", model.speed))
                stat("방향", String(format: "%.0f°", model.headingDegrees))
                stat("엔진 틱", "\(model.tick)")
                stat("매칭", "\(model.matched)")
                stat("누름", "\(model.pushCount)")
                stat("충격수신", "\(model.impulseApplied)")
            }
            .font(.callout)

            // 물리 진단(CharacterController)
            HStack(spacing: 24) {
                stat("콜리전", "\(model.collisionShapes)")
                stat("바닥Y", String(format: "%.2f", model.groundY))
                stat("의자Y", String(format: "%.2f", model.chairY))
                stat("pitch", String(format: "%.2f", model.pitch))
                stat("막힘", model.blocked ? "Y" : "N")
                stat("전복", model.fallen ? "Y" : "N")
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
        }
        .padding(28)
        .frame(width: 460)
        .disabled(isImmersiveTransitioning)
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
}
