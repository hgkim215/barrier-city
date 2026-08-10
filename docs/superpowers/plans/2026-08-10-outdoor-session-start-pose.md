# Outdoor Session Start Pose Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reset all wheelchair state on every immersive-space entry and start at the outdoor origin facing the cafe entrance.

**Architecture:** Add a small pure pose calculator plus a reset coordinator that depends on a narrow wheelchair-state protocol. `InteractionSetup.install` resolves the actual `DOOR1` center, then delegates reset and pose application to that coordinator before triggers and HUD behavior begin.

**Tech Stack:** Swift 5, simd, RealityKit, SwiftUI, standalone `swiftc` regression executable, visionOS Simulator build

## Global Constraints

- Outdoor start position is exactly `(0, 0)`.
- Heading follows the movement convention `forward = (-sin(heading), -cos(heading))`.
- Use the loaded `DOOR1` center when available and `InteractionTuning.doorFallbackCenter` otherwise.
- A coincident door center must fall back to the cafe-facing direction and must not produce NaN.
- Reset position, movement, input, collision, tilt, and fall state through the existing `AppModel.restart()` implementation.
- Do not change indoor spawn behavior, scene geometry, movement physics, quest progression, kiosk presentation, or NPC dialogue behavior.

---

## File Structure

- Create `Barrier City/Interaction/OutdoorSessionStart.swift`: pure outdoor pose calculation and reset orchestration.
- Create `Tests/OutdoorSessionStartTests.swift`: standalone behavior regression tests for heading and reset application.
- Modify `Barrier City/Interaction/InteractionSetup.swift`: make `AppModel` resettable and invoke the coordinator with the resolved cafe door center.

### Task 1: Outdoor Session Reset and Cafe-Facing Pose

**Files:**
- Create: `Barrier City/Interaction/OutdoorSessionStart.swift`
- Create: `Tests/OutdoorSessionStartTests.swift`
- Modify: `Barrier City/Interaction/InteractionSetup.swift:16-80`

**Interfaces:**
- Consumes: `AppModel.restart()`, `AppModel.posX`, `AppModel.posZ`, `AppModel.heading`, `InteractionTuning.doorFallbackCenter`, and the resolved `DOOR1` trigger center.
- Produces: `OutdoorStartPose`, `OutdoorSessionResettable`, `OutdoorSessionStart.pose(startPosition:doorCenter:fallbackDoorCenter:)`, and `OutdoorSessionStart.reset(_:startPosition:doorCenter:fallbackDoorCenter:)`.

- [x] **Step 1: Write the failing behavior tests**

Create `Tests/OutdoorSessionStartTests.swift`. The production mutations these tests catch are: wrong yaw sign, a removed coincident-target fallback, omitted restart delegation, and failure to overwrite the previous pose.

```swift
import Foundation

private func expectNear(_ actual: Float, _ expected: Float, _ message: String) {
    guard abs(actual - expected) < 0.0001 else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@MainActor
private final class WheelchairState: OutdoorSessionResettable {
    var posX: Float = 8
    var posZ: Float = -3
    var heading: Float = 0.25
    var restartCount = 0

    func restart() {
        restartCount += 1
        posX = 0
        posZ = 0
        heading = 0
    }
}

@main
@MainActor
struct OutdoorSessionStartTests {
    static func main() {
        let positiveZ = OutdoorSessionStart.pose(
            startPosition: .zero,
            doorCenter: SIMD2<Float>(0, 15),
            fallbackDoorCenter: SIMD2<Float>(0, 15))
        expectNear(positiveZ.heading, .pi, "positive-Z cafe faces 180 degrees")

        let diagonal = OutdoorSessionStart.pose(
            startPosition: .zero,
            doorCenter: SIMD2<Float>(1, 1),
            fallbackDoorCenter: SIMD2<Float>(0, 15))
        expectNear(-sin(diagonal.heading), 0.70710677, "diagonal heading faces cafe on X")
        expectNear(-cos(diagonal.heading), 0.70710677, "diagonal heading faces cafe on Z")

        let coincident = OutdoorSessionStart.pose(
            startPosition: .zero,
            doorCenter: .zero,
            fallbackDoorCenter: SIMD2<Float>(0, 15))
        expectNear(coincident.heading, .pi, "coincident marker uses cafe fallback")

        let state = WheelchairState()
        OutdoorSessionStart.reset(
            state,
            startPosition: .zero,
            doorCenter: SIMD2<Float>(0, 15),
            fallbackDoorCenter: SIMD2<Float>(0, 15))
        guard state.restartCount == 1 else {
            fatalError("FAIL: immersive entry must restart wheelchair state exactly once")
        }
        expectNear(state.posX, 0, "reset applies outdoor X")
        expectNear(state.posZ, 0, "reset applies outdoor Z")
        expectNear(state.heading, .pi, "reset applies cafe-facing heading")

        print("OutdoorSessionStartTests: PASS")
    }
}
```

- [x] **Step 2: Run the new test to verify RED**

Run:

```bash
xcrun swiftc \
  "Barrier City/Interaction/OutdoorSessionStart.swift" \
  Tests/OutdoorSessionStartTests.swift \
  -o /tmp/outdoor-session-start-tests
```

Expected: FAIL because `Barrier City/Interaction/OutdoorSessionStart.swift` and its public interfaces do not exist yet.

- [x] **Step 3: Implement the minimal pose and reset coordinator**

Create `Barrier City/Interaction/OutdoorSessionStart.swift`:

```swift
import simd

struct OutdoorStartPose: Equatable {
    let position: SIMD2<Float>
    let heading: Float
}

@MainActor
protocol OutdoorSessionResettable: AnyObject {
    var posX: Float { get set }
    var posZ: Float { get set }
    var heading: Float { get set }
    func restart()
}

enum OutdoorSessionStart {
    nonisolated static func pose(
        startPosition: SIMD2<Float>,
        doorCenter: SIMD2<Float>,
        fallbackDoorCenter: SIMD2<Float>
    ) -> OutdoorStartPose {
        var direction = doorCenter - startPosition
        if simd_length_squared(direction) < 0.000001 {
            direction = fallbackDoorCenter - startPosition
        }
        if simd_length_squared(direction) < 0.000001 {
            direction = SIMD2<Float>(0, 1)
        }
        direction = simd_normalize(direction)
        let rawHeading = atan2(-direction.x, -direction.y)
        let heading = rawHeading < 0 ? rawHeading + 2 * .pi : rawHeading
        return OutdoorStartPose(
            position: startPosition,
            heading: heading)
    }

    @MainActor
    static func reset(
        _ state: any OutdoorSessionResettable,
        startPosition: SIMD2<Float>,
        doorCenter: SIMD2<Float>,
        fallbackDoorCenter: SIMD2<Float>
    ) {
        let pose = pose(
            startPosition: startPosition,
            doorCenter: doorCenter,
            fallbackDoorCenter: fallbackDoorCenter)
        state.restart()
        state.posX = pose.position.x
        state.posZ = pose.position.y
        state.heading = pose.heading
    }
}
```

- [x] **Step 4: Run the focused test to verify GREEN**

Run:

```bash
xcrun swiftc \
  "Barrier City/Interaction/OutdoorSessionStart.swift" \
  Tests/OutdoorSessionStartTests.swift \
  -o /tmp/outdoor-session-start-tests
/tmp/outdoor-session-start-tests
```

Expected: `OutdoorSessionStartTests: PASS`.

- [x] **Step 5: Connect the reset coordinator to immersive installation**

In `InteractionSetup.swift`, add the conformance near the imports:

```swift
extension AppModel: OutdoorSessionResettable {}
```

After resolving `center` from `DOOR1` or the fallback and before assigning `im.triggers`, add:

```swift
OutdoorSessionStart.reset(
    appModel,
    startPosition: .zero,
    doorCenter: center,
    fallbackDoorCenter: InteractionTuning.doorFallbackCenter)
```

This ordering ensures the loaded map marker determines the heading while all stale physical and input state is cleared before the first interaction tick.

- [x] **Step 6: Run focused and existing standalone regression tests**

Run:

```bash
xcrun swiftc "Barrier City/Interaction/OutdoorSessionStart.swift" Tests/OutdoorSessionStartTests.swift -o /tmp/outdoor-session-start-tests
/tmp/outdoor-session-start-tests

xcrun swiftc "Barrier City/Quest/GuideFlowState.swift" Tests/GuideFlowStateTests.swift -o /tmp/guide-flow-state-tests
/tmp/guide-flow-state-tests

xcrun swiftc "Barrier City/Quest/QuestProgression.swift" "Barrier City/Quest/QuestModel.swift" Tests/QuestModelOutcomeTests.swift -o /tmp/quest-model-outcome-tests
/tmp/quest-model-outcome-tests

xcrun swiftc "Barrier City/Interaction/SceneTransitionSession.swift" Tests/SceneTransitionSessionTests.swift -o /tmp/scene-transition-session-tests
/tmp/scene-transition-session-tests

xcrun swiftc -parse-as-library Tests/LoopingGuidePlaybackContractTests.swift -o /tmp/looping-guide-playback-contract-tests
/tmp/looping-guide-playback-contract-tests "Barrier City/Quest/LoopingGuideVideoView.swift"

xcrun swiftc \
  "Barrier City/Interaction/SceneTransitionSession.swift" \
  "Barrier City/Interaction/InteractionModel.swift" \
  "Barrier City/Quest/GuideFlowState.swift" \
  Tests/InteractionFlowRegressionTests.swift \
  -o /tmp/interaction-flow-regression-tests
/tmp/interaction-flow-regression-tests
```

Expected:

```text
OutdoorSessionStartTests: PASS
GuideFlowStateTests: PASS
QuestModelOutcomeTests: PASS
SceneTransitionSessionTests: PASS
LoopingGuidePlaybackContractTests: PASS
InteractionFlowRegressionTests: PASS
```

- [x] **Step 7: Run package and app verification**

Run:

```bash
cd Packages/DialogueKit && swift test
xcodebuild \
  -scheme "Barrier City" \
  -project "Barrier City.xcodeproj" \
  -destination "generic/platform=visionOS Simulator" \
  -derivedDataPath /tmp/barrier-city-pr-validation \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: 54 DialogueKit tests pass with zero failures and Xcode reports `** BUILD SUCCEEDED **`.

- [x] **Step 8: Review the diff and commit**

Run:

```bash
git diff --check
git diff -- "Barrier City/Interaction/OutdoorSessionStart.swift" \
  "Barrier City/Interaction/InteractionSetup.swift" \
  Tests/OutdoorSessionStartTests.swift
git add "Barrier City/Interaction/OutdoorSessionStart.swift" \
  "Barrier City/Interaction/InteractionSetup.swift" \
  Tests/OutdoorSessionStartTests.swift \
  docs/superpowers/specs/2026-08-10-outdoor-session-start-pose-design.md \
  docs/superpowers/plans/2026-08-10-outdoor-session-start-pose.md
git commit -m "fix(interaction): reset outdoor immersive start pose"
```

- [ ] **Step 9: Manual visionOS Simulator acceptance**

1. Enter the immersive space and confirm the cafe entrance is centered ahead.
2. Move away from the origin and, if practical, induce a tilted or fallen state.
3. Exit the immersive space and re-enter it.
4. Confirm the wheelchair is back at the outdoor origin, upright and stationary, with the cafe entrance centered ahead.
