# Cafe Door Prompt Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start the outdoor wheelchair beyond the cafe-door trigger and render the entry prompt in front of the door after the user approaches.

**Architecture:** Keep `OutdoorSessionStart` as the pure start-position calculator and change only its tuning input to 3.0 m. Add a pure `InteractionPanelPlacement` calculation that selects the existing kiosk offset or the new door offset from `TriggerKind`; the RealityKit billboard presenter consumes that calculated world position.

**Tech Stack:** Swift 5, simd, RealityKit, standalone `swiftc` regression executable, visionOS Simulator build

## Global Constraints

- Outdoor spawn distance from the cafe door is exactly 3.0 m.
- Door trigger radius remains exactly 2.5 m, requiring approximately 0.5 m of approach.
- Door yes/no panels move exactly 0.6 m from their trigger world position toward the viewer.
- Kiosk billboard fallback retains its existing 0.8 m offset.
- Guide locking, door coordinates, movement physics, indoor spawn, kiosk state, quest progression, NPC dialogue, and scene loading remain unchanged.
- Automated verification does not replace user acceptance of spatial distance and visibility on Simulator or Vision Pro.

---

## File Structure

- Modify `Tests/InteractionFlowRegressionTests.swift`: add the cafe approach boundary and real panel-position behavior regression.
- Modify `Barrier City/Interaction/InteractionModel.swift`: update the spawn tuning, add the door offset, and expose a pure kind-aware panel-placement calculation.
- Modify `Barrier City/Interaction/InteractionSetup.swift`: consume the pure placement result in the existing RealityKit billboard path.

### Task 1: Require an Approach Before the Door Trigger Activates

**Files:**
- Modify: `Tests/InteractionFlowRegressionTests.swift`
- Modify: `Barrier City/Interaction/InteractionModel.swift:60-70`

**Interfaces:**
- Consumes: `OutdoorSessionStart.positionOutsideCafe(...)`, `InteractionModel.evaluate(...)`, and the existing `doorTriggerRadius` value of 2.5 m.
- Produces: `InteractionTuning.outdoorSpawnDistanceFromDoor == 3.0` and an outdoor start pose that remains outside the door trigger until the user moves 0.5 m toward it.

- [ ] **Step 1: Write the failing approach regression**

Add `expectNear` beside the existing `expect` helper in `Tests/InteractionFlowRegressionTests.swift`:

```swift
private func expectNear(_ actual: Float, _ expected: Float, _ message: String) {
    guard abs(actual - expected) < 0.0001 else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}
```

At the start of `main()`, add a real start-position and proximity evaluation. The regression catches a spawn-distance rollback to 1.25 m or any change that activates the 2.5 m trigger at the initial pose:

```swift
let doorCenter = SIMD2<Float>(0, -6)
let outdoorStart = OutdoorSessionStart.positionOutsideCafe(
    doorCenter: doorCenter,
    cafeCenter: .zero,
    fallbackDoorCenter: doorCenter,
    distanceFromDoor: InteractionTuning.outdoorSpawnDistanceFromDoor)
expectNear(outdoorStart.y, -9, "outdoor spawn remains 3 m beyond the door")

let door = ProximityTrigger(
    id: "door.enter",
    center: doorCenter,
    radius: InteractionTuning.doorTriggerRadius,
    prompt: "안으로 입장하시겠습니까?")
let initialVerdict = InteractionModel.evaluate(
    playerX: outdoorStart.x,
    playerZ: outdoorStart.y,
    triggers: [door],
    activeID: nil,
    dismissedID: nil)
expect(initialVerdict.showID, nil, "door prompt stays hidden at the outdoor spawn")

let approachedVerdict = InteractionModel.evaluate(
    playerX: outdoorStart.x,
    playerZ: outdoorStart.y + 0.5,
    triggers: [door],
    activeID: nil,
    dismissedID: nil)
expect(approachedVerdict.showID, "door.enter", "half-meter approach reaches the door trigger")
```

- [ ] **Step 2: Run the focused regression to verify RED**

Run:

```bash
xcrun swiftc \
  "Barrier City/Interaction/OutdoorSessionStart.swift" \
  "Barrier City/Interaction/KioskInteractionState.swift" \
  "Barrier City/Interaction/KioskReachAttemptDetector.swift" \
  "Barrier City/Interaction/SceneTransitionSession.swift" \
  "Barrier City/Interaction/InteractionModel.swift" \
  "Barrier City/Quest/GuideFlowState.swift" \
  Tests/InteractionFlowRegressionTests.swift \
  -o /tmp/interaction-flow-regression-tests
/tmp/interaction-flow-regression-tests
```

Expected: FAIL with `outdoor spawn remains 3 m beyond the door` because the production distance is still 1.25 m.

- [ ] **Step 3: Implement the minimal spawn tuning change**

In `InteractionTuning`:

```swift
/// 카페 문에서 건물 바깥 방향으로 떨어진 Outdoor 시작 거리(m).
/// 문 트리거 바깥에서 시작해 약 0.5m 접근한 뒤 알림이 활성화된다.
static let outdoorSpawnDistanceFromDoor: Float = 3.0
```

- [ ] **Step 4: Run the focused regression to verify GREEN**

Re-run the Step 2 commands.

Expected: `InteractionFlowRegressionTests: PASS`.

- [ ] **Step 5: Commit the approach slice**

```bash
git add "Barrier City/Interaction/InteractionModel.swift" Tests/InteractionFlowRegressionTests.swift
git commit -m "fix: move outdoor spawn beyond cafe door trigger"
```

### Task 2: Pull the Door Prompt in Front of the Door Geometry

**Files:**
- Modify: `Tests/InteractionFlowRegressionTests.swift`
- Modify: `Barrier City/Interaction/InteractionModel.swift:60-90`
- Modify: `Barrier City/Interaction/InteractionSetup.swift:164-220`

**Interfaces:**
- Consumes: a panel world position, viewer world position, and `TriggerKind`.
- Produces: `InteractionPanelPlacement.worldPosition(_:toward:kind:) -> SIMD3<Float>`, which moves `.yesNoPrompt` by 0.6 m and `.kioskScreen` by 0.8 m toward the viewer.

- [ ] **Step 1: Write the failing placement regression**

Add these assertions after the approach regression. They exercise the real kind-aware position result and catch a zero door offset, reversed movement, or accidental kiosk-offset change:

```swift
let doorPanelPosition = InteractionPanelPlacement.worldPosition(
    SIMD3<Float>(0, 1.7, -6),
    toward: .zero,
    kind: .yesNoPrompt)
expectNear(doorPanelPosition.y, 1.7, "door prompt preserves panel height")
expectNear(doorPanelPosition.z, -5.4, "door prompt moves 0.6 m toward the viewer")

let kioskPanelPosition = InteractionPanelPlacement.worldPosition(
    SIMD3<Float>(3, 1.7, 4),
    toward: .zero,
    kind: .kioskScreen)
expectNear(kioskPanelPosition.x, 2.52, "kiosk offset preserves its 0.8 m behavior on X")
expectNear(kioskPanelPosition.z, 3.36, "kiosk offset preserves its 0.8 m behavior on Z")
```

- [ ] **Step 2: Run the focused regression to verify RED**

Run the Task 1 Step 2 commands.

Expected: compiler failure `cannot find 'InteractionPanelPlacement' in scope`.

- [ ] **Step 3: Implement the minimal pure placement calculation**

In `InteractionModel.swift`, add the door constant and the pure calculation:

```swift
/// 문 패널을 문 표면에서 사용자 쪽으로 당기는 거리(m).
static let doorPanelForwardOffset: Float = 0.6
```

```swift
enum InteractionPanelPlacement {
    nonisolated static func worldPosition(
        _ worldPosition: SIMD3<Float>,
        toward viewerPosition: SIMD3<Float>,
        kind: TriggerKind
    ) -> SIMD3<Float> {
        let forwardOffset: Float
        switch kind {
        case .yesNoPrompt:
            forwardOffset = InteractionTuning.doorPanelForwardOffset
        case .kioskScreen:
            forwardOffset = InteractionTuning.kioskPanelForwardOffset
        }

        var result = worldPosition
        let towardViewer = SIMD2(
            viewerPosition.x - worldPosition.x,
            viewerPosition.z - worldPosition.z)
        let distance = simd_length(towardViewer)
        guard forwardOffset > 0, distance > 0.001 else { return result }
        let displacement = towardViewer / distance * forwardOffset
        result.x += displacement.x
        result.z += displacement.y
        return result
    }
}
```

- [ ] **Step 4: Connect the pure result to the RealityKit billboard**

Remove the `forwardOffset` argument from `showBillboard` and both call sites. After obtaining the panel's current world position, apply the kind-aware result:

```swift
var worldPos = panel.position(relativeTo: nil)
worldPos = InteractionPanelPlacement.worldPosition(
    worldPos,
    toward: .zero,
    kind: t.kind)
panel.setPosition(worldPos, relativeTo: nil)
```

Keep the existing yaw calculation after this block. This preserves the panel's height and viewer-facing rotation.

- [ ] **Step 5: Run the focused regression to verify GREEN**

Re-run the Task 1 Step 2 commands.

Expected: `InteractionFlowRegressionTests: PASS`.

- [ ] **Step 6: Run complete automated verification**

Run the standalone regressions, then run DialogueKit and the app build:

```bash
xcrun swiftc "Barrier City/Interaction/OutdoorSessionStart.swift" Tests/OutdoorSessionStartTests.swift -o /tmp/outdoor-session-start-tests
/tmp/outdoor-session-start-tests

xcrun swiftc "Barrier City/Quest/GuideFlowState.swift" Tests/GuideFlowStateTests.swift -o /tmp/guide-flow-state-tests
/tmp/guide-flow-state-tests

xcrun swiftc "Barrier City/Quest/QuestProgression.swift" "Barrier City/Quest/QuestModel.swift" Tests/QuestModelOutcomeTests.swift -o /tmp/quest-model-outcome-tests
/tmp/quest-model-outcome-tests

xcrun swiftc "Barrier City/Interaction/SceneTransitionSession.swift" Tests/SceneTransitionSessionTests.swift -o /tmp/scene-transition-session-tests
/tmp/scene-transition-session-tests

xcrun swiftc "Barrier City/ImmersiveSessionState.swift" Tests/ImmersiveSessionStateTests.swift -o /tmp/immersive-session-state-tests
/tmp/immersive-session-state-tests

xcrun swiftc "Barrier City/Interaction/KioskInteractionState.swift" Tests/KioskInteractionStateTests.swift -o /tmp/kiosk-interaction-state-tests
/tmp/kiosk-interaction-state-tests

xcrun swiftc "Barrier City/Interaction/KioskReachAttemptDetector.swift" Tests/KioskReachAttemptDetectorTests.swift -o /tmp/kiosk-reach-attempt-detector-tests
/tmp/kiosk-reach-attempt-detector-tests

xcrun swiftc "Barrier City/Interaction/KioskScreenLayout.swift" Tests/KioskScreenLayoutTests.swift -o /tmp/kiosk-screen-layout-tests
/tmp/kiosk-screen-layout-tests

xcrun swiftc "Barrier City/ImmersiveSceneCatalog.swift" Tests/ImmersiveSceneCatalogTests.swift -o /tmp/immersive-scene-catalog-tests
/tmp/immersive-scene-catalog-tests "Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets"

xcrun swiftc -parse-as-library Tests/LoopingGuidePlaybackContractTests.swift -o /tmp/looping-guide-playback-contract-tests
/tmp/looping-guide-playback-contract-tests "Barrier City/Quest/LoopingGuideVideoView.swift"

xcrun swiftc -parse-as-library Tests/HandTrackingLifecycleContractTests.swift -o /tmp/hand-tracking-lifecycle-contract-tests
/tmp/hand-tracking-lifecycle-contract-tests "Barrier City/ImmersiveView.swift" "Barrier City/HandTrackingManager.swift"

xcrun swiftc \
  "Barrier City/Interaction/OutdoorSessionStart.swift" \
  "Barrier City/Interaction/KioskInteractionState.swift" \
  "Barrier City/Interaction/KioskReachAttemptDetector.swift" \
  "Barrier City/Interaction/SceneTransitionSession.swift" \
  "Barrier City/Interaction/InteractionModel.swift" \
  "Barrier City/Quest/GuideFlowState.swift" \
  Tests/InteractionFlowRegressionTests.swift \
  -o /tmp/interaction-flow-regression-tests
/tmp/interaction-flow-regression-tests

swift test --package-path Packages/DialogueKit
xcodebuild \
  -scheme "Barrier City" \
  -project "Barrier City.xcodeproj" \
  -destination "generic/platform=visionOS Simulator" \
  -derivedDataPath /tmp/barrier-city-door-prompt-validation \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: all standalone regressions and DialogueKit tests pass with zero failures; Xcode reports `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Review and commit the placement slice**

```bash
git diff --check
git diff -- "Barrier City/Interaction/InteractionModel.swift" \
  "Barrier City/Interaction/InteractionSetup.swift" \
  Tests/InteractionFlowRegressionTests.swift
git add "Barrier City/Interaction/InteractionModel.swift" \
  "Barrier City/Interaction/InteractionSetup.swift" \
  Tests/InteractionFlowRegressionTests.swift
git commit -m "fix: place cafe door prompt in front of geometry"
```

Do not stage or modify the unrelated user-owned `Barrier City.xcodeproj/project.pbxproj` ordering change.
