# Onboarding Guide Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Figma의 소개·3단계 조작 가이드·Mission 카드·누적 Mission List 디자인을 현재 visionOS 체험에 적용하고, 안내 중에는 휠체어 이동과 공간 상호작용을 안전하게 잠근다.

**Architecture:** `GuideFlowState`가 순수 상태 전이를 담당하고 `GuideFlowModel`이 기존 `QuestModel`과 `AppModel`을 조정한다. 하나의 `ExperienceGuideView` attachment가 중앙 모달과 좌측 상단 Mission List를 상태에 따라 렌더링하며, `QuestHUDFollower`는 표시 모드에 맞는 공간 배치만 담당한다.

**Tech Stack:** Swift 5, SwiftUI, Observation, RealityKit, ARKit `WorldTrackingProvider`, AVKit/AVFoundation, visionOS 26.2+, FFmpeg(더미 MP4 생성), `xcodebuild`

## Global Constraints

- 작업 브랜치는 `codex/onboarding-guide-redesign`이며 `develop`에 직접 커밋하지 않는다.
- 디자인 기준은 Figma 파일 `Hl56XSp23HYGlBXGEOgCv5`, 노드 `147:54`, `147:67`, `147:80`, `147:98`, `122:5`, `122:3`, `122:8`, `122:10`이다.
- 몰입 공간에 들어올 때마다 `introduction`부터 초기화하고, 소개 및 Guide 1~3에서는 항상 `건너뛰기`를 제공한다.
- `introduction`, `tutorial`, `missionAnnouncement`, `completionAnnouncement`에서는 이동·문·키오스크·NPC 상호작용을 잠근다.
- 기존 미션 순서 `.enteredIndoor → .kioskFailed → .npcHelpDone`를 유지한다.
- Mission List는 완료한 항목과 현재 항목만 누적하며 미래 항목은 숨긴다. 최종 확인 뒤에는 세 항목 모두 `Clear`로 유지한다.
- 실제 플레이 영상 제작은 범위 밖이다. 초기 자산은 4초, 1280×720, H.264, 무음 `onboarding-placeholder.mp4` 하나다.
- 단계별 실제 영상 이름은 `guide-wheel-control`, `guide-turning`, `guide-straight-drive`로 예약한다.
- 새로운 외부 런타임 의존성을 추가하지 않는다.
- `.superpowers/` Visual Companion 산출물은 커밋하지 않는다.
- 각 작업 뒤 `git diff --check`를 실행하고 명시된 파일만 stage한다.

---

## File Map

| File | Responsibility |
|---|---|
| `Barrier City/Quest/GuideFlowState.swift` | 순수 phase/action 전이, 잠금·배치·표시 개수 파생값 |
| `Barrier City/Quest/GuideFlowModel.swift` | Observable 조정자, Quest 결과와 phase 연결, 입력 초기화 호출 |
| `Barrier City/Quest/GuideContent.swift` | 3개 tutorial 및 3개 mission의 확정 문구와 영상 이름 |
| `Barrier City/Quest/ExperienceGuideView.swift` | phase별 루트 전환, 공통 glass 스타일과 소개 화면 |
| `Barrier City/Quest/TutorialGuideView.swift` | 2열 영상 가이드, 이전·다음·건너뛰기 |
| `Barrier City/Quest/MissionGuideViews.swift` | Mission 시작, 누적 목록, 체험 완료 화면 |
| `Barrier City/Quest/LoopingGuideVideoView.swift` | 단계별 영상→공통 더미→정적 폴백 로딩 및 무음 반복 |
| `Barrier City/Quest/QuestModel.swift` | Quest 전이를 결과값으로 반환 |
| `Barrier City/Quest/QuestHUDFollower.swift` | 중앙/좌측 상단 배치, placement 변경 시 즉시 재배치 |
| `Barrier City/Quest/QuestSetup.swift` | attachment·follower·subscription 설치 및 정리 |
| `Barrier City/AppModel.swift` | 가이드 phase 변경 및 잠금 프레임용 입력 초기화 API |
| `Barrier City/HandTrackingManager.swift` | 잠금 중 손 입력 생산 차단 |
| `Barrier City/WheelchairMovementSystem.swift` | 잠금 중 이동 적분 차단 |
| `Barrier City/Interaction/InteractionSetup.swift` | 잠금 중 공간 트리거와 패널 차단 |
| `Barrier City/NPC/NPCClerkController.swift` | 잠금 중 NPC 대화 패널 숨김, 완료 이벤트 라우팅 |
| `Barrier City/Interaction/KioskOrderView.swift` | 장벽 메시지 확인 뒤 `.kioskFailed` 발행 |
| `Barrier City/Interaction/SceneSwitcher.swift` | `.enteredIndoor` 이벤트 라우팅 |
| `Barrier City/ImmersiveView.swift` | 새 루트 뷰 attachment와 Quest 수명주기 연결 |
| `Barrier City/Resources/onboarding-placeholder.mp4` | 세 tutorial이 공유하는 더미 루프 영상 |
| `Tests/GuideFlowStateTests.swift` | 독립 실행형 상태 전이 회귀 테스트 |
| `Tests/QuestModelOutcomeTests.swift` | 독립 실행형 Quest 결과 계약 테스트 |

---

### Task 1: Pure Guide Flow State Machine

**Files:**
- Create: `Barrier City/Quest/GuideFlowState.swift`
- Create: `Tests/GuideFlowStateTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `GuidePhase`, `GuidePlacement`, `GuideAction`, `GuideFlowState.send(_:)`, `GuideFlowState.isInteractionLocked`, `GuideFlowState.placement`, `GuideFlowState.visibleMissionCount`

- [ ] **Step 1: Write the failing standalone state tests**

```swift
// Tests/GuideFlowStateTests.swift
import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
struct GuideFlowStateTests {
    static func main() {
        var normal = GuideFlowState()
        expect(normal.phase, .introduction, "initial phase")
        expect(normal.isInteractionLocked, true, "introduction locks input")
        expect(normal.placement, .centerModal, "introduction is centered")

        normal.send(.confirmIntroduction)
        expect(normal.phase, .tutorial(index: 0), "intro confirmation")
        normal.send(.nextTutorial)
        normal.send(.nextTutorial)
        expect(normal.phase, .tutorial(index: 2), "third tutorial")
        normal.send(.nextTutorial)
        expect(normal.phase, .missionAnnouncement(index: 0), "tutorial starts mission one")
        normal.send(.confirmMission)
        expect(normal.phase, .missionActive(index: 0), "mission one active")
        expect(normal.isInteractionLocked, false, "active mission unlocks input")
        expect(normal.placement, .upperLeadingHUD, "active mission uses HUD placement")

        normal.send(.questAdvanced(nextIndex: 1))
        expect(normal.phase, .missionAnnouncement(index: 1), "next mission announcement")
        expect(normal.visibleMissionCount, 2, "completed plus current missions visible")
        normal.send(.confirmMission)
        normal.send(.questAdvanced(nextIndex: 2))
        normal.send(.confirmMission)
        normal.send(.questAdvanced(nextIndex: nil))
        expect(normal.phase, .completionAnnouncement, "last quest opens completion")
        normal.send(.confirmCompletion)
        expect(normal.phase, .completed, "completion acknowledgement")
        expect(normal.visibleMissionCount, 3, "all missions remain visible")

        var skipped = GuideFlowState()
        skipped.send(.skipOnboarding)
        expect(skipped.phase, .missionAnnouncement(index: 0), "skip opens mission one")

        var backward = GuideFlowState(phase: .tutorial(index: 1))
        backward.send(.previousTutorial)
        expect(backward.phase, .tutorial(index: 0), "previous tutorial")
        backward.send(.previousTutorial)
        expect(backward.phase, .tutorial(index: 0), "previous clamps at zero")

        var invalid = GuideFlowState()
        invalid.send(.questAdvanced(nextIndex: 1))
        expect(invalid.phase, .introduction, "quest event ignored outside active mission")

        var failOpen = GuideFlowState()
        failOpen.send(.failOpen(activeMissionIndex: 0))
        expect(failOpen.phase, .missionActive(index: 0), "attachment failure unlocks mission")
        expect(failOpen.isInteractionLocked, false, "fail-open is unlocked")

        print("GuideFlowStateTests: PASS")
    }
}
```

- [ ] **Step 2: Run the state tests and verify they fail**

Run:

```bash
xcrun swiftc -parse-as-library \
  "Barrier City/Quest/GuideFlowState.swift" \
  Tests/GuideFlowStateTests.swift \
  -o /tmp/barrier-city-guide-flow-tests
```

Expected: FAIL because `GuideFlowState.swift` and its types do not exist.

- [ ] **Step 3: Implement the pure state machine**

```swift
// Barrier City/Quest/GuideFlowState.swift
import Foundation

enum GuidePhase: Equatable {
    case introduction
    case tutorial(index: Int)
    case missionAnnouncement(index: Int)
    case missionActive(index: Int)
    case completionAnnouncement
    case completed
}

enum GuidePlacement: Equatable {
    case centerModal
    case upperLeadingHUD
}

enum GuideAction: Equatable {
    case confirmIntroduction
    case previousTutorial
    case nextTutorial
    case skipOnboarding
    case confirmMission
    case questAdvanced(nextIndex: Int?)
    case confirmCompletion
    case failOpen(activeMissionIndex: Int)
}

struct GuideFlowState: Equatable {
    private(set) var phase: GuidePhase

    init(phase: GuidePhase = .introduction) {
        self.phase = phase
    }

    var isInteractionLocked: Bool {
        switch phase {
        case .missionActive, .completed: false
        case .introduction, .tutorial, .missionAnnouncement, .completionAnnouncement: true
        }
    }

    var placement: GuidePlacement {
        switch phase {
        case .missionActive, .completed: .upperLeadingHUD
        default: .centerModal
        }
    }

    var visibleMissionCount: Int {
        switch phase {
        case .missionAnnouncement(let index), .missionActive(let index): index + 1
        case .completionAnnouncement, .completed: 3
        case .introduction, .tutorial: 0
        }
    }

    mutating func send(_ action: GuideAction) {
        switch (phase, action) {
        case (.introduction, .confirmIntroduction):
            phase = .tutorial(index: 0)
        case (.introduction, .skipOnboarding), (.tutorial, .skipOnboarding):
            phase = .missionAnnouncement(index: 0)
        case (.tutorial(let index), .previousTutorial):
            phase = .tutorial(index: max(0, index - 1))
        case (.tutorial(let index), .nextTutorial) where index < 2:
            phase = .tutorial(index: index + 1)
        case (.tutorial, .nextTutorial):
            phase = .missionAnnouncement(index: 0)
        case (.missionAnnouncement(let index), .confirmMission):
            phase = .missionActive(index: index)
        case (.missionActive, .questAdvanced(let nextIndex)):
            phase = nextIndex.map { .missionAnnouncement(index: $0) } ?? .completionAnnouncement
        case (.completionAnnouncement, .confirmCompletion):
            phase = .completed
        case (_, .failOpen(let activeMissionIndex)):
            phase = .missionActive(index: max(0, min(2, activeMissionIndex)))
        default:
            break
        }
    }
}
```

- [ ] **Step 4: Run the state tests and verify they pass**

```bash
xcrun swiftc -parse-as-library \
  "Barrier City/Quest/GuideFlowState.swift" \
  Tests/GuideFlowStateTests.swift \
  -o /tmp/barrier-city-guide-flow-tests && \
  /tmp/barrier-city-guide-flow-tests
```

Expected: `GuideFlowStateTests: PASS`.

- [ ] **Step 5: Commit the state machine**

```bash
git add "Barrier City/Quest/GuideFlowState.swift" Tests/GuideFlowStateTests.swift
git diff --cached --check
git commit -m "feat(guide): add tested onboarding state machine"
```

---

### Task 2: Quest Progression Outcome Contract

**Files:**
- Modify: `Barrier City/Quest/QuestModel.swift`
- Test: `Tests/QuestModelOutcomeTests.swift`

**Interfaces:**
- Consumes: `QuestProgression.nextIndex(currentIndex:stepCount:eventMatchesCurrent:)`
- Produces: `QuestAdvanceOutcome`, `QuestModel.advance(on:) -> QuestAdvanceOutcome`

- [ ] **Step 1: Write the failing Quest outcome tests**

```swift
// Tests/QuestModelOutcomeTests.swift
import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else { fatalError("FAIL: \(message)") }
}

@main
@MainActor
struct QuestModelOutcomeTests {
    static func main() {
        let model = QuestModel()
        expect(model.advance(on: .kioskFailed), .ignored, "out-of-order event")
        expect(model.currentIndex, 0, "ignored event does not advance")

        let first = model.steps[0]
        let second = model.steps[1]
        expect(model.advance(on: .enteredIndoor),
               .advanced(completed: first, next: second),
               "first event advances")
        expect(model.currentIndex, 1, "current index after first event")

        _ = model.advance(on: .kioskFailed)
        let last = model.steps[2]
        expect(model.advance(on: .npcHelpDone),
               .advanced(completed: last, next: nil),
               "last event returns no next step")
        expect(model.currentStep, nil, "quest completed")
        expect(model.advance(on: .npcHelpDone), .ignored, "duplicate completion ignored")

        model.reset()
        expect(model.currentIndex, 0, "reset")
        print("QuestModelOutcomeTests: PASS")
    }
}
```

- [ ] **Step 2: Run the test and verify the current void API fails to compile**

```bash
xcrun swiftc -parse-as-library \
  "Barrier City/Quest/QuestProgression.swift" \
  "Barrier City/Quest/QuestModel.swift" \
  Tests/QuestModelOutcomeTests.swift \
  -o /tmp/barrier-city-quest-outcome-tests
```

Expected: FAIL because `advance(on:)` returns `Void` and `QuestAdvanceOutcome` is undefined.

- [ ] **Step 3: Add an explicit outcome while preserving the legacy HUD bridge**

Add before `QuestModel`:

```swift
enum QuestAdvanceOutcome: Equatable {
    case ignored
    case advanced(completed: QuestStep, next: QuestStep?)
}
```

Keep `justCompletedStep`, `completedHoldSeconds`, and the delayed reset temporarily so the existing `QuestHUDView` continues to compile until Task 6. Replace `advance(on:)` with:

```swift
@discardableResult
func advance(on event: QuestEvent) -> QuestAdvanceOutcome {
    guard let step = currentStep else { return .ignored }
    let nextIndex = QuestProgression.nextIndex(
        currentIndex: currentIndex,
        stepCount: steps.count,
        eventMatchesCurrent: event == step.completionEvent)
    guard nextIndex != currentIndex else { return .ignored }

    justCompletedStep = step
    currentIndex = nextIndex
    Task { [weak self] in
        try? await Task.sleep(for: .seconds(QuestTuning.completedHoldSeconds))
        guard self?.justCompletedStep?.id == step.id else { return }
        self?.justCompletedStep = nil
    }
    return .advanced(completed: step, next: currentStep)
}
```

`reset()`은 기존처럼 `currentIndex = 0`과 `justCompletedStep = nil`을 수행한다. 이 호환 상태는 새 UI가 연결되는 Task 6에서 제거한다.

- [ ] **Step 4: Run both standalone logic tests**

```bash
xcrun swiftc -parse-as-library \
  "Barrier City/Quest/QuestProgression.swift" \
  "Barrier City/Quest/QuestModel.swift" \
  Tests/QuestModelOutcomeTests.swift \
  -o /tmp/barrier-city-quest-outcome-tests && \
  /tmp/barrier-city-quest-outcome-tests

/tmp/barrier-city-guide-flow-tests
```

Expected: both print `PASS`.

- [ ] **Step 5: Commit the Quest contract**

```bash
git add "Barrier City/Quest/QuestModel.swift" Tests/QuestModelOutcomeTests.swift
git diff --cached --check
git commit -m "refactor(quest): return explicit progression outcomes"
```

---

### Task 3: Observable Guide Coordinator and Phase-Change Reset

**Files:**
- Create: `Barrier City/Quest/GuideFlowModel.swift`
- Modify: `Barrier City/AppModel.swift`

**Interfaces:**
- Consumes: `GuideFlowState`, `GuideAction`, `QuestModel.advance(on:)`
- Produces: `GuideFlowModel.shared`, view action methods, `AppModel.prepareForGuidePhaseChange(isLocked:)`, `AppModel.discardGuideLockedInput()`

- [ ] **Step 1: Add AppModel input reset APIs**

Add below `releaseWheelHandInput()`:

```swift
func prepareForGuidePhaseChange(isLocked: Bool) {
    vL = 0
    vR = 0
    pendingImpulseLeft = 0
    pendingImpulseRight = 0
    brakeRequested = false
    releaseWheelHandInput()
    stopFistDrive(
        requestRecenter: true,
        status: isLocked && testFistDriveEnabled ? "가이드 확인 중" : nil)
}

func discardGuideLockedInput() {
    vL = 0
    vR = 0
    pendingImpulseLeft = 0
    pendingImpulseRight = 0
    brakeRequested = false
    releaseWheelHandInput()
    fistDriveActive = false
    fistDriveForwardAxis = 0
    fistDriveTurnAxis = 0
    fistDriveTargetLeft = 0
    fistDriveTargetRight = 0
    fistDriveLastUpdate = 0
    fistDriveHand = ""
}
```

- [ ] **Step 2: Create the observable coordinator**

```swift
// Barrier City/Quest/GuideFlowModel.swift
import Observation

@Observable
@MainActor
final class GuideFlowModel {
    static let shared = GuideFlowModel()

    private(set) var state: GuideFlowState

    init(state: GuideFlowState = GuideFlowState()) {
        self.state = state
    }

    var phase: GuidePhase { state.phase }
    var isInteractionLocked: Bool { state.isInteractionLocked }
    var placement: GuidePlacement { state.placement }
    var visibleMissionCount: Int { state.visibleMissionCount }

    func reset() {
        QuestModel.shared.reset()
        state = GuideFlowState()
        AppModel.current?.prepareForGuidePhaseChange(isLocked: true)
    }

    func confirmIntroduction() { apply(.confirmIntroduction) }
    func previousTutorial() { apply(.previousTutorial) }
    func nextTutorial() { apply(.nextTutorial) }
    func skipOnboarding() { apply(.skipOnboarding) }
    func confirmMission() { apply(.confirmMission) }
    func confirmCompletion() { apply(.confirmCompletion) }

    func handleQuestEvent(_ event: QuestEvent) {
        guard case .missionActive = state.phase else { return }
        switch QuestModel.shared.advance(on: event) {
        case .ignored:
            return
        case .advanced(_, let next):
            apply(.questAdvanced(nextIndex: next == nil ? nil : QuestModel.shared.currentIndex))
        }
    }

    func failOpen() {
        let index = min(2, max(0, QuestModel.shared.currentIndex))
        apply(.failOpen(activeMissionIndex: index))
    }

    private func apply(_ action: GuideAction) {
        let wasLocked = state.isInteractionLocked
        state.send(action)
        if wasLocked != state.isInteractionLocked {
            AppModel.current?.prepareForGuidePhaseChange(isLocked: state.isInteractionLocked)
        }
    }
}
```

- [ ] **Step 3: Build to verify the coordinator compiles**

```bash
xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'generic/platform=visionOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **`. The compatibility property retained in Task 2 keeps the old HUD buildable until the atomic UI replacement in Task 6.

- [ ] **Step 4: Commit the coordinator and reset APIs**

```bash
git add "Barrier City/Quest/GuideFlowModel.swift" "Barrier City/AppModel.swift"
git diff --cached --check
git commit -m "feat(guide): coordinate onboarding and quest phases"
```

---

### Task 4: Input and Spatial Interaction Gates

**Files:**
- Modify: `Barrier City/HandTrackingManager.swift:143-183`
- Modify: `Barrier City/WheelchairMovementSystem.swift:85-100`
- Modify: `Barrier City/Interaction/InteractionSetup.swift:91-110`
- Modify: `Barrier City/NPC/NPCClerkController.swift:97-126`

**Interfaces:**
- Consumes: `GuideFlowModel.shared.isInteractionLocked`, `AppModel.discardGuideLockedInput()`
- Produces: no movement, proximity trigger, kiosk/door panel, or NPC dialogue while a guide modal is locked

- [ ] **Step 1: Block hand-input production while locked**

In `HandTrackingManager.process(_:model:)`, after the existing `useHandTracking` guard, add:

```swift
guard !GuideFlowModel.shared.isInteractionLocked else {
    model.discardGuideLockedInput()
    resetAllTrackingState(allowImmediateFistCapture: false)
    return
}
```

- [ ] **Step 2: Block movement integration while locked**

In `WheelchairMovementSystem.update(context:)`, immediately after resolving `model` and `worldRoot`, add:

```swift
if GuideFlowModel.shared.isInteractionLocked {
    model.discardGuideLockedInput()
    Self.applyWorld(worldRoot, model: model)
    return
}
```

- [ ] **Step 3: Give the NPC controller a guide-lock hook**

Add near `installDialoguePanel`:

```swift
func setGuideInteractionLocked(_ locked: Bool) {
    guard locked else { return }
    dialoguePanel?.isEnabled = false
    isDialogueVisible = false
}
```

This hook deliberately does not reset NPC placement or completed dialogue state.

- [ ] **Step 4: Gate proximity and NPC updates**

In `InteractionSetup.tick(deltaTime:)`, move the existing `guard !im.isTransitioning` below the new lock branch. Immediately after resolving `InteractionModel.shared`, add:

```swift
if GuideFlowModel.shared.isInteractionLocked {
    im.activeTrigger = nil
    im.panelEntity?.isEnabled = false
    im.kioskPanelEntity?.isEnabled = false
    app.npcClerk.setGuideInteractionLocked(true)
    return
}
guard !im.isTransitioning else { return }
app.npcClerk.setGuideInteractionLocked(false)
```

- [ ] **Step 5: Build and check the gate sites**

```bash
rg -n "isInteractionLocked|discardGuideLockedInput|setGuideInteractionLocked" \
  "Barrier City/HandTrackingManager.swift" \
  "Barrier City/WheelchairMovementSystem.swift" \
  "Barrier City/Interaction/InteractionSetup.swift" \
  "Barrier City/NPC/NPCClerkController.swift"

xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'generic/platform=visionOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **`; movement, proximity panels, kiosk/door activation, and NPC dialogue all have explicit lock checks.

- [ ] **Step 6: Commit the interaction gates**

```bash
git add "Barrier City/HandTrackingManager.swift" \
  "Barrier City/WheelchairMovementSystem.swift" \
  "Barrier City/Interaction/InteractionSetup.swift" \
  "Barrier City/NPC/NPCClerkController.swift"
git diff --cached --check
git commit -m "feat(guide): lock movement and interactions during prompts"
```

---

### Task 5: Looping Placeholder Video

**Files:**
- Create: `Barrier City/Resources/onboarding-placeholder.mp4`
- Create: `Barrier City/Quest/LoopingGuideVideoView.swift`

**Interfaces:**
- Consumes: a resource basename such as `guide-wheel-control` and an optional placeholder basename
- Produces: `LoopingGuideVideoView(resourceName:placeholderResourceName:)` with step-specific→placeholder→static fallback behavior

- [ ] **Step 1: Verify the placeholder does not exist yet**

```bash
test ! -f "Barrier City/Resources/onboarding-placeholder.mp4"
```

Expected: exit 0.

- [ ] **Step 2: Generate the exact shared placeholder asset**

```bash
mkdir -p "Barrier City/Resources"
ffmpeg -y -f lavfi -i "color=c=0x1C2328:s=1280x720:d=4:r=30" \
  -vf "drawbox=x='mod(t*260\,1080)':y=548:w=200:h=18:color=0x12D8EE@0.95:t=fill,drawtext=fontfile=/System/Library/Fonts/SFNS.ttf:text='Guide video placeholder':fontcolor=white:fontsize=54:x=(w-text_w)/2:y=(h-text_h)/2" \
  -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
  "Barrier City/Resources/onboarding-placeholder.mp4"
```

- [ ] **Step 3: Verify codec, size, duration, and absence of audio**

```bash
ffprobe -v error -show_entries \
  stream=codec_name,width,height,codec_type:format=duration \
  -of default=noprint_wrappers=1 \
  "Barrier City/Resources/onboarding-placeholder.mp4"
```

Expected output includes `codec_name=h264`, `width=1280`, `height=720`, one `codec_type=video`, no `codec_type=audio`, and duration near `4.000000`.

- [ ] **Step 4: Implement the looping playback component**

```swift
// Barrier City/Quest/LoopingGuideVideoView.swift
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

    init(resourceName: String,
         placeholderResourceName: String? = "onboarding-placeholder") {
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
```

- [ ] **Step 5: Build and confirm the MP4 is copied into the app bundle**

```bash
xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'generic/platform=visionOS Simulator' build

find ~/Library/Developer/Xcode/DerivedData -path '*Barrier City.app/onboarding-placeholder.mp4' -print -quit
```

Expected: `** BUILD SUCCEEDED **`, and `find` prints one bundled MP4 path.

- [ ] **Step 6: Commit the media component and asset**

```bash
git add "Barrier City/Quest/LoopingGuideVideoView.swift" \
  "Barrier City/Resources/onboarding-placeholder.mp4"
git diff --cached --check
git commit -m "feat(guide): add looping placeholder video"
```

---

### Task 6: Figma-Aligned Guide UI

**Files:**
- Create: `Barrier City/Quest/GuideContent.swift`
- Create: `Barrier City/Quest/ExperienceGuideView.swift`
- Create: `Barrier City/Quest/TutorialGuideView.swift`
- Create: `Barrier City/Quest/MissionGuideViews.swift`
- Modify: `Barrier City/Quest/QuestModel.swift`
- Modify: `Barrier City/ImmersiveView.swift`
- Delete: `Barrier City/Quest/QuestHUDView.swift`

**Interfaces:**
- Consumes: `GuideFlowModel`, `QuestModel`, `LoopingGuideVideoView`
- Produces: `ExperienceGuideView(model:)`, tutorial and mission child views with previewable value inputs

- [ ] **Step 1: Load official Figma design context before UI code**

Invoke `figma:figma-design-to-code`, then call Figma `get_design_context` for file key `Hl56XSp23HYGlBXGEOgCv5` and the eight nodes in Global Constraints. Treat Figma output as a reference: preserve the project’s SwiftUI/glass patterns and do not copy generated web code.

Expected: typography, dimensions, color, and spacing evidence for the four intro/guide screens and four mission states.

- [ ] **Step 2: Add immutable guide copy and resource descriptors**

```swift
// Barrier City/Quest/GuideContent.swift
import Foundation

struct TutorialGuideStep: Identifiable, Equatable {
    let id: Int
    let title: String
    let detail: String
    let videoResourceName: String
}

struct MissionNarrative: Equatable {
    let situation: String
    let action: String
}

enum GuideContent {
    static let introductionTitle = "휠체어 체험을 시작합니다."
    static let introductionBody = "휠체어를 직접 조작하며\n일상 속 접근성 장벽을 경험해 보세요."
    static let completionTitle = "Barrier City 체험을 완료했습니다."
    static let completionBody = "접근하기 어려운 공간과 서비스가\n일상에 어떤 장벽이 되는지 돌아보세요."

    static let tutorials = [
        TutorialGuideStep(id: 0, title: "바퀴 조작하기",
                          detail: "바퀴를 잡으면 파란색으로 표시됩니다.\n손을 앞뒤로 움직여 바퀴를 회전시켜 보세요.",
                          videoResourceName: "guide-wheel-control"),
        TutorialGuideStep(id: 1, title: "방향 전환하기",
                          detail: "한쪽 바퀴를 움직여\n원하는 방향으로 회전할 수 있습니다.",
                          videoResourceName: "guide-turning"),
        TutorialGuideStep(id: 2, title: "직진 · 후진하기",
                          detail: "양쪽 바퀴를 같은 방향으로 움직이면\n앞으로 또는 뒤로 이동할 수 있습니다.",
                          videoResourceName: "guide-straight-drive")
    ]

    static let missions = [
        MissionNarrative(situation: "음료 한 잔이 마시고 싶다.\n앞에 보이는 카페로 들어가자.",
                         action: "휠체어를 이동하여 카페 입구로 이동하세요."),
        MissionNarrative(situation: "이번에 신상으로 나온\n‘레인보우 마카롱 스무디’가 마시고 싶다.",
                         action: "키오스크에서 음료 주문을 시도해 보세요."),
        MissionNarrative(situation: "키오스크 화면이 너무 높아\n혼자 주문하기 어렵다.",
                         action: "직원에게 직접 도움을 요청해 보세요.")
    ]
}
```

- [ ] **Step 3: Implement the tutorial card with the exact actions**

`TutorialGuideView` must accept values and closures so every state is previewable:

```swift
struct TutorialGuideView: View {
    let step: TutorialGuideStep
    let totalCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            LoopingGuideVideoView(resourceName: step.videoResourceName)
                .frame(width: 383, height: 356)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("건너뛰기", action: onSkip).buttonStyle(.plain)
                }
                Text("Guide \(step.id + 1) / \(totalCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .overlay(Capsule().stroke(.cyan, lineWidth: 1))
                Spacer()
                Text(step.title).font(.title2.bold())
                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                Spacer()
                HStack(spacing: 20) {
                    if step.id > 0 {
                        Button(action: onPrevious) { Image(systemName: "chevron.left") }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                    }
                    Button(step.id == totalCount - 1 ? "시작하기" : "다음", action: onNext)
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 52)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .padding(20)
        .frame(width: 767, height: 396)
        .glassBackgroundEffect()
    }
}
```

- [ ] **Step 4: Implement mission start, list, and completion views**

Use these public signatures:

```swift
struct MissionAnnouncementView: View {
    let narrative: MissionNarrative
    let onConfirm: () -> Void
}

struct MissionListView: View {
    let steps: [QuestStep]
    let visibleCount: Int
    let allCompleted: Bool
}

struct ExperienceCompletionView: View {
    let onConfirm: () -> Void
}
```

`MissionListView` renders `steps.prefix(visibleCount)` and computes status exactly as:

```swift
let isClear = allCompleted || offset < visibleCount - 1
Text(isClear ? "Clear" : "Progress")
    .font(.caption2.bold())
    .foregroundStyle(isClear ? Color.secondary : Color.cyan)
    .padding(.horizontal, 12).padding(.vertical, 8)
    .overlay(Capsule().stroke(isClear ? Color.secondary : Color.cyan, lineWidth: 1))
```

Use width `400`, outer padding `28`, row vertical padding `10`, and `glassBackgroundEffect()`. `MissionAnnouncementView` uses the narrative table from Step 2, a cyan `Mission` capsule, and a 52pt `확인` button. `ExperienceCompletionView` displays the exact title and body from the spec and a 52pt `확인` button.

- [ ] **Step 5: Implement the root phase switch and introduction**

```swift
struct ExperienceGuideView: View {
    let model: GuideFlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: GuideFlowModel = .shared) { self.model = model }

    var body: some View {
        Group {
            switch model.phase {
            case .introduction:
                IntroductionCardView(onConfirm: model.confirmIntroduction,
                                     onSkip: model.skipOnboarding)
            case .tutorial(let index):
                TutorialGuideView(step: GuideContent.tutorials[index],
                                  totalCount: GuideContent.tutorials.count,
                                  onPrevious: model.previousTutorial,
                                  onNext: model.nextTutorial,
                                  onSkip: model.skipOnboarding)
            case .missionAnnouncement(let index):
                MissionAnnouncementView(narrative: GuideContent.missions[index],
                                        onConfirm: model.confirmMission)
            case .missionActive:
                MissionListView(steps: QuestModel.shared.steps,
                                visibleCount: model.visibleMissionCount,
                                allCompleted: false)
            case .completionAnnouncement:
                ExperienceCompletionView(onConfirm: model.confirmCompletion)
            case .completed:
                MissionListView(steps: QuestModel.shared.steps,
                                visibleCount: 3,
                                allCompleted: true)
            }
        }
        .id(String(describing: model.phase))
        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        .animation(.easeOut(duration: 0.22), value: model.phase)
    }
}
```

`IntroductionCardView` uses width `767`, padding `48`, `GuideContent.introductionTitle`, `GuideContent.introductionBody`, a cyan `Barrier City` capsule, `확인`, and top-trailing `건너뛰기`. `ExperienceCompletionView` uses `GuideContent.completionTitle` and `GuideContent.completionBody`, so all approved copy has one source of truth.

- [ ] **Step 6: Add previews for every required visual state**

Add `#Preview` blocks for introduction, all three tutorial values, all three mission narratives, Mission List with `visibleCount` 1/2/3 and `allCompleted`, and completion. Add the static media fallback preview with `LoopingGuideVideoView(resourceName: "missing-preview-video", placeholderResourceName: nil)`. Child previews pass empty closures and do not mutate the singleton.

- [ ] **Step 7: Atomically replace the attachment and remove the legacy HUD bridge**

In `ImmersiveView`, change the `questHUD` attachment content from `QuestHUDView()` to `ExperienceGuideView()`.

In `QuestModel`, remove `justCompletedStep`, `completedHoldSeconds`, the delayed reset `Task` inside `advance(on:)`, and the `justCompletedStep = nil` line in `reset()`. Keep the explicit `QuestAdvanceOutcome` return contract added in Task 2.

Delete `Barrier City/Quest/QuestHUDView.swift` with `apply_patch`, then build:

```bash
xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'generic/platform=visionOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **` and no references to `justCompletedStep` or `QuestHUDView`.

- [ ] **Step 8: Commit the guide UI**

```bash
git add "Barrier City/Quest/GuideContent.swift" \
  "Barrier City/Quest/ExperienceGuideView.swift" \
  "Barrier City/Quest/TutorialGuideView.swift" \
  "Barrier City/Quest/MissionGuideViews.swift" \
  "Barrier City/Quest/QuestModel.swift" \
  "Barrier City/ImmersiveView.swift" \
  "Barrier City/Quest/QuestHUDView.swift"
git diff --cached --check
git commit -m "feat(guide): build Figma-aligned onboarding UI"
```

---

### Task 7: Spatial Placement and Guide Lifecycle

**Files:**
- Modify: `Barrier City/Quest/QuestHUDFollower.swift`
- Modify: `Barrier City/Quest/QuestModel.swift` (`QuestTuning` only)
- Modify: `Barrier City/Quest/QuestSetup.swift`
- Modify: `Barrier City/ImmersiveView.swift`

**Interfaces:**
- Consumes: `GuideFlowModel.shared.placement`, `ExperienceGuideView`
- Produces: `QuestHUDFollower.update(panel:dt:placement:)`, `QuestSetup.stop()`, centered modal and upper-leading HUD placement

- [ ] **Step 1: Replace single-position tuning with per-placement tuning**

In `QuestTuning`, keep common `forwardDistance = 1.2`, dead zone, and smoothing values, then define:

```swift
static let centerLateralOffset: Float = 0
static let centerVerticalOffset: Float = -0.05
static let hudLateralOffset: Float = -0.4
static let hudVerticalOffset: Float = 0.2
static let centerFallbackPosition = SIMD3<Float>(0, 1.45, -1.2)
static let hudFallbackPosition = SIMD3<Float>(-0.4, 1.65, -1.2)
```

- [ ] **Step 2: Make follower target calculation placement-aware**

Change the signature to:

```swift
func update(panel: Entity, dt: Float, placement: GuidePlacement)
```

Add `private var lastPlacement: GuidePlacement?`. At the start of update:

```swift
if placement != lastPlacement {
    placed = false
    lastPlacement = placement
}
```

Change `targetPose()` to accept placement and select offsets:

```swift
let lateral = placement == .centerModal
    ? QuestTuning.centerLateralOffset : QuestTuning.hudLateralOffset
let vertical = placement == .centerModal
    ? QuestTuning.centerVerticalOffset : QuestTuning.hudVerticalOffset
let pos = head + forward * QuestTuning.forwardDistance
    + right * lateral + SIMD3(0, vertical, 0)
```

Use the matching center/HUD fallback when no device anchor exists. Keep yaw-only billboard and existing lazy-follow smoothing.

- [ ] **Step 3: Update QuestSetup install and add deterministic cleanup**

Add the `stop()` implementation below first. At install start call `stop()` and then `GuideFlowModel.shared.reset()` so repeated installation cannot retain an old subscription or panel. If attachment lookup fails:

```swift
print("⚠️ questHUD attachment 없음 — 안내 UI 없이 체험 계속")
GuideFlowModel.shared.failOpen()
return
```

Update the frame callback:

```swift
f.update(panel: panel,
         dt: Float(event.deltaTime),
         placement: GuideFlowModel.shared.placement)
```

Add:

```swift
static func stop() {
    subscription?.cancel()
    subscription = nil
    follower?.stop()
    follower = nil
    hudPanel?.removeFromParent()
    hudPanel = nil
}
```

- [ ] **Step 4: Connect cleanup**

The attachment already renders `ExperienceGuideView()` after Task 6. At the beginning of `ImmersiveView.onDisappear`, add `QuestSetup.stop()` before stopping hand tracking.

- [ ] **Step 5: Build and verify old symbols are gone**

```bash
rg -n "QuestHUDView|completedHoldSeconds|fallbackPosition|lateralOffset|verticalOffset" \
  "Barrier City/Quest" "Barrier City/ImmersiveView.swift" || true

xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'generic/platform=visionOS Simulator' build
```

Expected: build succeeds and no obsolete `QuestHUDView` or transient completion symbols remain.

- [ ] **Step 6: Commit placement and lifecycle**

```bash
git add "Barrier City/Quest/QuestHUDFollower.swift" \
  "Barrier City/Quest/QuestModel.swift" \
  "Barrier City/Quest/QuestSetup.swift" \
  "Barrier City/ImmersiveView.swift"
git diff --cached --check
git commit -m "feat(guide): place and clean up spatial guide panels"
```

---

### Task 8: Quest Event Routing and Kiosk Acknowledgement

**Files:**
- Modify: `Barrier City/Interaction/SceneSwitcher.swift:119`
- Modify: `Barrier City/Interaction/KioskOrderView.swift:20-55`
- Modify: `Barrier City/NPC/NPCClerkController.swift:431-436`

**Interfaces:**
- Consumes: `GuideFlowModel.handleQuestEvent(_:)`
- Produces: all three Quest events enter through the guide coordinator; kiosk barrier remains visible until explicit acknowledgement

- [ ] **Step 1: Route indoor entry through GuideFlowModel**

Replace:

```swift
QuestModel.shared.advance(on: .enteredIndoor)
```

with:

```swift
GuideFlowModel.shared.handleQuestEvent(.enteredIndoor)
```

- [ ] **Step 2: Delay kiosk completion until the barrier message is acknowledged**

The `키오스크 사용하기` button now only sets:

```swift
im.kioskTooHighShown = true
```

In the `kioskTooHighShown` branch, add:

```swift
Button("확인") {
    im.kioskPanelEntity?.isEnabled = false
    GuideFlowModel.shared.handleQuestEvent(.kioskFailed)
}
.buttonStyle(.borderedProminent)
.frame(minHeight: 52)
```

This guarantees the accessibility barrier copy is seen before Mission 3 replaces the kiosk panel.

- [ ] **Step 3: Route NPC completion through GuideFlowModel**

Replace the `.orderPlaced` handler call with:

```swift
GuideFlowModel.shared.handleQuestEvent(.npcHelpDone)
phase = .completed
```

- [ ] **Step 4: Verify no production site bypasses the coordinator**

```bash
rg -n "QuestModel\.shared\.advance" "Barrier City" -g '*.swift'
```

Expected: no matches outside tests or `GuideFlowModel.swift`.

- [ ] **Step 5: Run logic tests and full build**

```bash
/tmp/barrier-city-guide-flow-tests
/tmp/barrier-city-quest-outcome-tests
xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'generic/platform=visionOS Simulator' build
```

Expected: both logic suites print `PASS`; app build succeeds.

- [ ] **Step 6: Commit the event integration**

```bash
git add "Barrier City/Interaction/SceneSwitcher.swift" \
  "Barrier City/Interaction/KioskOrderView.swift" \
  "Barrier City/NPC/NPCClerkController.swift"
git diff --cached --check
git commit -m "feat(guide): route mission events through guide flow"
```

---

### Task 9: Full Verification and Simulator Acceptance

**Files:**
- Modify only if tuning is required: `Barrier City/Quest/QuestModel.swift`, `Barrier City/Quest/ExperienceGuideView.swift`, `Barrier City/Quest/TutorialGuideView.swift`, `Barrier City/Quest/MissionGuideViews.swift`

**Interfaces:**
- Consumes: completed implementation from Tasks 1–8
- Produces: build evidence and a manually accepted end-to-end flow

- [ ] **Step 1: Rebuild and run both standalone logic suites from source**

```bash
xcrun swiftc -parse-as-library \
  "Barrier City/Quest/GuideFlowState.swift" \
  Tests/GuideFlowStateTests.swift \
  -o /tmp/barrier-city-guide-flow-tests && \
  /tmp/barrier-city-guide-flow-tests

xcrun swiftc -parse-as-library \
  "Barrier City/Quest/QuestProgression.swift" \
  "Barrier City/Quest/QuestModel.swift" \
  Tests/QuestModelOutcomeTests.swift \
  -o /tmp/barrier-city-quest-outcome-tests && \
  /tmp/barrier-city-quest-outcome-tests
```

Expected: both print `PASS`.

- [ ] **Step 2: Verify the media asset contract**

```bash
ffprobe -v error -show_entries \
  stream=codec_name,width,height,codec_type:format=duration \
  -of default=noprint_wrappers=1 \
  "Barrier City/Resources/onboarding-placeholder.mp4"
```

Expected: H.264, 1280×720, video-only, approximately 4 seconds.

- [ ] **Step 3: Run the final visionOS Simulator build**

```bash
xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'generic/platform=visionOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Perform the manual acceptance sequence**

Verify in order:

1. Entry opens the introduction centered and movement controls do nothing.
2. `확인` opens Guide 1; previous/next behavior is correct through Guide 3.
3. All four onboarding screens can skip directly to Mission 1 announcement.
4. Placeholder video loops, is muted, and has no controls.
5. Mission 1 `확인` moves the panel to upper-leading Mission List and unlocks movement.
6. Cafe entry clears Mission 1 and opens centered Mission 2 while movement is locked.
7. Kiosk barrier message remains visible until its `확인`; then Mission 3 opens.
8. NPC order completion opens final completion card; its `확인` leaves all three rows Clear.
9. Exit/re-entry restarts at introduction and does not duplicate WorldTracking subscriptions.
10. With WorldTracking unavailable, center/HUD fallback positions remain readable and no permanent lock occurs.

- [ ] **Step 5: Inspect the final diff and repository state**

```bash
git diff --check
git status --short
git log --oneline --decorate -10
```

Expected: no whitespace errors; `.superpowers/` is the only allowed untracked path; implementation files are committed.

- [ ] **Step 6: Commit only simulator-driven tuning changes if Step 4 required them**

```bash
git add "Barrier City/Quest/QuestModel.swift" \
  "Barrier City/Quest/ExperienceGuideView.swift" \
  "Barrier City/Quest/TutorialGuideView.swift" \
  "Barrier City/Quest/MissionGuideViews.swift"
git diff --cached --quiet || git commit -m "fix(guide): tune spatial onboarding presentation"
```

Do not create an empty commit when no tuning was needed.

---

## Final Handoff

After Task 9 passes:

1. Push `codex/onboarding-guide-redesign`.
2. Open a PR targeting `develop`, never `main`.
3. Include the design spec, plan, automated logic test output, video contract, and final `xcodebuild` result in the PR description.
4. Do not merge the PR unless the user explicitly requests it.
