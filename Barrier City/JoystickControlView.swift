//
//  JoystickControlView.swift
//  Barrier City
//
//  시뮬레이터에서 카페 맵을 '편하게' 둘러보기 위한 연속 조이스틱 이동 입력.
//
//  기존 ControlPanelView의 '밀기' 버튼은 한 번 누를 때마다 한 스트로크(impulse)라
//  계속 이동하려면 반복해서 눌러야 한다. 이 뷰는 조이스틱을 꾹 누르고 있는 동안
//  이윤서 엔진의 '잡기(클러치)' 경로(leftGrabbed/rightGrabbed + handSpeedLeft/Right)에
//  목표 속도를 계속 주입해, 손으로 양쪽 바퀴를 잡고 미는 것과 동일하게 연속 주행시킨다.
//  놓으면 grabbed가 풀려 관성으로 굴러가다 마찰로 멈춘다.
//
//  (키보드 이동은 visionOS 시뮬레이터가 WASD/화살표를 자체 카메라 조작으로 가로채
//   앱까지 도달하지 않아 제거했다. 조이스틱만 사용한다.)
//
//  주의: 이 경로는 시뮬레이터(useHandTracking=false)에서 비어 있어 안전하게 사용한다.
//  실기기 손 추적(HandTrackingManager)이 켜지면 그쪽이 같은 필드를 쓰므로, 이 뷰는
//  손 추적을 끈 디버그 상황에서만 노출하는 것을 전제로 한다.
//

import SwiftUI

struct JoystickControlView: View {

    @Environment(AppModel.self) private var model

    /// 조이스틱을 끝까지 밀었을 때의 전진 목표 바퀴 속도(m/s).
    private static let maxWheelSpeed: Float = 1.3
    /// 회전 목표(좌/우 바퀴 속도차의 절반, m/s). 전진과 분리해 낮춰야 덜 어지럽다.
    private static let maxTurnSpeed: Float = 0.4

    var body: some View {
        VStack(spacing: 8) {
            Text("조이스틱 (연속 이동)")
                .font(.headline)
            Text("꾹 눌러 이동 · 위=전진 · 아래=후진 · 좌우=회전 · 놓으면 관성 후 정지")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            JoystickPad(
                onChange: { v in drive(forwardAxis: Float(v.height), turnAxis: Float(v.width)) },
                onEnd: { release() })
        }
    }

    /// 정규화 축(위=+forward, 오른쪽=+turn)을 좌/우 바퀴 목표 속도로 변환해 주입한다.
    /// 회전은 낮은 게인 + 제곱 커브로 중앙 미세조작을 쉽게 한다.
    /// 오른쪽으로 밀면 왼쪽 바퀴가 더 빨라 오른쪽으로 회전한다(엔진 규약 omega=(vR-vL)/wheelBase).
    private func drive(forwardAxis: Float, turnAxis: Float) {
        let forward = clampUnit(forwardAxis) * Self.maxWheelSpeed
        let t = clampUnit(turnAxis)
        let turn = t * abs(t) * Self.maxTurnSpeed   // 제곱 커브(부호 유지)
        model.leftGrabbed = true
        model.rightGrabbed = true
        model.handSpeedLeft = forward + turn
        model.handSpeedRight = forward - turn
    }

    /// 손을 뗀 상태: 잡기 해제 → 바퀴는 관성으로 굴러가다 마찰로 멈춘다.
    private func release() {
        model.leftGrabbed = false
        model.rightGrabbed = false
        model.handSpeedLeft = 0
        model.handSpeedRight = 0
    }

    private func clampUnit(_ v: Float) -> Float { max(-1, min(1, v)) }
}

/// 원형 패드 안에서 드래그하는 조이스틱. 정규화 벡터(-1...1, 위가 +)를 콜백한다.
private struct JoystickPad: View {

    var onChange: (CGSize) -> Void
    var onEnd: () -> Void

    private let radius: CGFloat = 80
    private let knob: CGFloat = 52
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Circle().fill(.gray.opacity(0.2))
            Circle().stroke(.gray.opacity(0.4), lineWidth: 2)
            Circle().fill(.blue.opacity(0.85))
                .frame(width: knob, height: knob)
                .offset(offset)
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let maxR = radius - knob / 2
                    var t = g.translation
                    let mag = sqrt(t.width * t.width + t.height * t.height)
                    if mag > maxR, mag > 0 {
                        t.width *= maxR / mag
                        t.height *= maxR / mag
                    }
                    offset = t
                    // SwiftUI translation.height는 아래로 양수 → 위를 +forward로 뒤집는다.
                    onChange(CGSize(width: t.width / maxR, height: -t.height / maxR))
                }
                .onEnded { _ in
                    offset = .zero
                    onEnd()
                })
    }
}

#Preview(windowStyle: .automatic) {
    JoystickControlView()
        .environment(AppModel())
        .padding()
}
