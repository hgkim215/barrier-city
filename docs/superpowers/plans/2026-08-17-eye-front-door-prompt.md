# Eye-Front Door Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the cafe entry question as a selectable user-relative modal directly in front of the user's eyes when the door trigger activates.

**Architecture:** Keep proximity and button actions unchanged. Reparent only the entry prompt from the moving `worldRoot` to the stationary `RealityView` content root, and make the existing pure placement helper return the fixed eye-front coordinate for `.yesNoPrompt` while preserving the kiosk's surface-offset calculation.

**Tech Stack:** Swift 5, SwiftUI, RealityKit, simd, standalone `swiftc` regression executables, visionOS Simulator build

## Global Constraints

- The entry prompt world position is exactly `SIMD3<Float>(0, 1.45, -1.2)`.
- The entry prompt is parented directly to the `RealityView` content root, not `worldRoot`.
- The door trigger radius remains exactly 1.1 m.
- Guide-locked phases continue to suppress the entry prompt.
- `예` continues to request the Indoor scene transition.
- `아니요` continues to dismiss the prompt until range exit and re-entry.
- The kiosk billboard fallback retains its existing 0.8 m surface offset and parent.
- Do not alter safe spawn, wheelchair physics, scene assets, quest progression, kiosk screen, NPC flow, or dialogue behavior.
- Preserve the user's existing unstaged Xcode project-file change.
- Automated verification does not replace direct Simulator or Vision Pro spatial acceptance.

---

## File Structure

- Modify `Tests/InteractionFlowRegressionTests.swift`: verify the user-relative entry position, kiosk isolation, and dismissal/re-entry behavior.
- Modify `Barrier City/Interaction/InteractionModel.swift`: define the eye-front position and make the kind-aware placement helper return it for `.yesNoPrompt`.
- Modify `Barrier City/Interaction/InteractionSetup.swift`: attach the entry prompt to `RealityView` content instead of `worldRoot` and consume the kind-aware placement result.
- Modify `Barrier City/Interaction/EntryPromptView.swift`: update the stale spatial-parent comment only; button implementation remains unchanged.
- Modify `Barrier City/ImmersiveView.swift`: update the stale attachment comment only.

### Task 1: Move the Door Prompt to the User's Eye-Front Space

**Files:**
- Modify: `Tests/InteractionFlowRegressionTests.swift`
- Modify: `Barrier City/Interaction/InteractionModel.swift`
- Modify: `Barrier City/Interaction/InteractionSetup.swift`
- Modify: `Barrier City/Interaction/EntryPromptView.swift`
- Modify: `Barrier City/ImmersiveView.swift`

**Interfaces:**
- Consumes: `TriggerKind`, `InteractionPanelPlacement.worldPosition(_:toward:kind:)`, `RealityViewContent`, and the existing `EntryPromptView` actions.
- Produces: `InteractionTuning.doorPromptEyeFrontPosition == SIMD3<Float>(0, 1.45, -1.2)` and a `.yesNoPrompt` placement result independent of the door's world position.

- [ ] **Step 1: Write the failing eye-front placement regression**

Replace the current door-surface assertion in `Tests/InteractionFlowRegressionTests.swift` with an arbitrary door/viewer fixture. The literal expected values catch any regression that couples the prompt back to door geometry:

```swift
let doorPanelPosition = InteractionPanelPlacement.worldPosition(
    SIMD3<Float>(8, 3, 9),
    toward: SIMD3<Float>(4, 1, 2),
    kind: .yesNoPrompt)
expectNear(doorPanelPosition.x, 0, "door prompt stays horizontally centered on the user")
expectNear(doorPanelPosition.y, 1.45, "door prompt stays at the seated eye line")
expectNear(doorPanelPosition.z, -1.2, "door prompt stays at a comfortable eye-front distance")
```

Keep the existing kiosk assertions unchanged. Add real proximity assertions proving dismissal persists inside the trigger, clears after leaving beyond the exit hysteresis, and permits display after re-entry:

```swift
let dismissedVerdict = InteractionModel.evaluate(
    playerX: outdoorStart.x,
    playerZ: outdoorStart.y + 0.5,
    triggers: [door],
    activeID: nil,
    dismissedID: "door.enter")
expect(dismissedVerdict.showID, nil, "dismissed door prompt stays hidden inside the trigger")

let leftVerdict = InteractionModel.evaluate(
    playerX: doorCenter.x,
    playerZ: doorCenter.y + 2,
    triggers: [door],
    activeID: nil,
    dismissedID: "door.enter")
expect(leftVerdict.clearDismissed, true, "leaving the door range clears dismissal")

let reenteredVerdict = InteractionModel.evaluate(
    playerX: outdoorStart.x,
    playerZ: outdoorStart.y + 0.5,
    triggers: [door],
    activeID: nil,
    dismissedID: nil)
expect(reenteredVerdict.showID, "door.enter", "re-entering the door range shows the prompt again")
```

- [ ] **Step 2: Run the focused regression to verify RED**

Run:

```bash
xcrun swiftc \
  "Barrier City/Interaction/OutdoorSessionStart.swift" \
  "Barrier City/Interaction/KioskInteractionState.swift" \
  "Barrier City/Interaction/KioskReachAttemptDetector.swift" \
  "Barrier City/Interaction/KioskScreenLayout.swift" \
  "Barrier City/Interaction/KioskScreenPresenter.swift" \
  "Barrier City/Interaction/SceneTransitionSession.swift" \
  "Barrier City/Interaction/InteractionModel.swift" \
  "Barrier City/Quest/GuideFlowState.swift" \
  Tests/InteractionFlowRegressionTests.swift \
  -o /tmp/interaction-flow-regression-tests
/tmp/interaction-flow-regression-tests
```

Expected: FAIL at `door prompt stays horizontally centered on the user` because the existing helper still offsets the arbitrary door position instead of returning the eye-front position.

- [ ] **Step 3: Implement the pure eye-front placement behavior**

In `InteractionTuning`, replace `doorPanelForwardOffset` with:

```swift
/// 문 선택 패널을 사용자 눈앞 정면에 두는 content-root 월드 좌표(m).
nonisolated static let doorPromptEyeFrontPosition = SIMD3<Float>(0, 1.45, -1.2)
```

Change the `.yesNoPrompt` branch of `InteractionPanelPlacement.worldPosition` to return that value immediately, while leaving the `.kioskScreen` calculation unchanged:

```swift
switch kind {
case .yesNoPrompt:
    return InteractionTuning.doorPromptEyeFrontPosition
case .kioskScreen:
    break
}

var result = worldPosition
let towardViewer = SIMD2(
    viewerPosition.x - worldPosition.x,
    viewerPosition.z - worldPosition.z)
let distance = simd_length(towardViewer)
guard distance > 0.001 else { return result }
let displacement = towardViewer / distance * InteractionTuning.kioskPanelForwardOffset
result.x += displacement.x
result.z += displacement.y
return result
```

- [ ] **Step 4: Attach the entry prompt to the content root**

In `InteractionSetup.install`, obtain `entryPrompt` before the `worldRoot` block, disable it, and add it directly to `content`:

```swift
if let panel = attachments.entity(for: "entryPrompt") {
    panel.isEnabled = false
    content.add(panel)
    im.panelEntity = panel
}
```

Keep only kiosk and NPC installation inside the existing `worldRoot` block. Update the comments in `InteractionSetup.swift`, `EntryPromptView.swift`, and `ImmersiveView.swift` to describe a content-root, user-relative prompt. Keep `showBillboard`'s kind-aware placement and yaw calculation, which now place `.yesNoPrompt` at `(0, 1.45, -1.2)` with identity-facing yaw.

- [ ] **Step 5: Run the focused regression to verify GREEN**

Re-run Step 2.

Expected: exit code 0. The eye-front, kiosk, and dismissal/re-entry assertions all pass.

- [ ] **Step 6: Run complete verification**

Run every standalone regression executable under `Tests`, then:

```bash
swift test --package-path Packages/DialogueKit
xcodebuild -quiet \
  -project "Barrier City.xcodeproj" \
  -scheme "Barrier City" \
  -sdk xrsimulator \
  -destination 'generic/platform=visionOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: all standalone regressions exit 0, 87 DialogueKit tests pass with zero failures, and the visionOS Simulator build exits 0. Direct spatial acceptance remains pending until the user verifies prompt visibility and button selection.

- [ ] **Step 7: Commit the implementation slice**

```bash
git add \
  "Barrier City/ImmersiveView.swift" \
  "Barrier City/Interaction/EntryPromptView.swift" \
  "Barrier City/Interaction/InteractionModel.swift" \
  "Barrier City/Interaction/InteractionSetup.swift" \
  Tests/InteractionFlowRegressionTests.swift
git commit -m "fix: show cafe entry prompt in front of user"
```
