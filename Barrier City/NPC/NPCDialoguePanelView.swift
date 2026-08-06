import SwiftUI

/// 계산대 위에 표시되는 몰입 공간용 대화 패널.
/// 별도 테스트 창과 같은 controller를 사용하므로 호감도·미션·애니메이션이 동기화된다.
struct NPCDialoguePanelView: View {
    let controller: NPCDialogueController
    let clerk: NPCClerkController

    var body: some View {
        VStack(spacing: 8) {
            Text("점원: \(clerk.phase.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)

            DialogueTurnView(controller: controller,
                             title: "직원과 대화",
                             showsManualControls: false)

#if DEBUG
            HStack(spacing: 8) {
                Text("애니메이션 테스트")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(NPCAnimationCue.allCases, id: \.rawValue) { cue in
                    Button(cue.rawValue) { clerk.playForTesting(cue) }
                        .buttonStyle(.bordered)
                }
            }
#endif
        }
        .padding(12)
        .glassBackgroundEffect()
    }
}
