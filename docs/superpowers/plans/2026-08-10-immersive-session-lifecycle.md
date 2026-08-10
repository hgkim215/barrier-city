# Immersive Session Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `체험 종료` reliably return the control window to `체험 시작` and allow repeated immersive-space entry.

**Architecture:** Replace the mutable immersive Boolean and view-local transition flag with one pure four-phase session state in `AppModel`. Every open receives a generation number; async results and view teardown apply only when that generation still owns the current session.

**Tech Stack:** Swift 5, SwiftUI immersive-space environment actions, Observation, standalone `swiftc` regression executable, visionOS Simulator

## Global Constraints

- Closed sessions display `체험 시작` and allow opening.
- Opening sessions display `여는 중…` and disable controls.
- Open sessions display `체험 종료` and allow dismissal.
- Closing sessions display `종료 중…` and disable controls.
- A completed or system-driven dismissal must return to `closed` without depending exclusively on `onDisappear`.
- A stale disappearance received while a new session is `opening` must not cancel the new opening.
- A stale async result or view teardown from an older generation must not affect an already appeared replacement session.
- Every disappearing view must stop its own ARKit session, while only the current generation may clear shared model input.
- Preserve existing open cancellation and error messages.
- Do not alter scene loading, spawn placement, physics, quest progression, NPC behavior, or immersive-space IDs.

---

### Task 1: Shared Immersive Session State

**Files:**
- Create: `Barrier City/ImmersiveSessionState.swift`
- Create: `Tests/ImmersiveSessionStateTests.swift`
- Create: `Tests/HandTrackingLifecycleContractTests.swift`

**Interfaces:**
- Produces: `ImmersiveSessionPhase`, generation-aware begin/complete and appear/disappear methods, plus `isImmersive`, `isTransitioning`, and `controlTitle`.

- [x] **Step 1: Write the failing state regression test**

Create `Tests/ImmersiveSessionStateTests.swift`:

```swift
import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
struct ImmersiveSessionStateTests {
    static func main() {
        var normal = ImmersiveSessionState()
        expect(normal.phase, .closed, "initial phase")
        expect(normal.controlTitle, "체험 시작", "closed title")
        expect(normal.isTransitioning, false, "closed controls enabled")

        normal.send(.beginOpen)
        expect(normal.phase, .opening, "begin open")
        expect(normal.controlTitle, "여는 중…", "opening title")
        expect(normal.isTransitioning, true, "opening controls disabled")
        normal.send(.openSucceeded)
        expect(normal.phase, .open, "open succeeds")
        expect(normal.controlTitle, "체험 종료", "open title")
        expect(normal.isImmersive, true, "open is immersive")

        normal.send(.beginClose)
        expect(normal.phase, .closing, "begin close")
        expect(normal.controlTitle, "종료 중…", "closing title")
        expect(normal.isTransitioning, true, "closing controls disabled")
        normal.send(.closeSucceeded)
        expect(normal.phase, .closed, "close returns to start")
        expect(normal.controlTitle, "체험 시작", "close restores start title")
        expect(normal.isImmersive, false, "closed is not immersive")

        normal.send(.beginOpen)
        normal.send(.openSucceeded)
        expect(normal.phase, .open, "second experience can open")

        var cancelled = ImmersiveSessionState()
        cancelled.send(.beginOpen)
        cancelled.send(.openFailed)
        expect(cancelled.phase, .closed, "cancelled open returns to start")

        var systemDriven = ImmersiveSessionState()
        systemDriven.send(.appeared)
        expect(systemDriven.phase, .open, "appearance reconciles external open")
        systemDriven.send(.disappeared)
        expect(systemDriven.phase, .closed, "disappearance reconciles external close")

        var staleDisappear = ImmersiveSessionState()
        staleDisappear.send(.beginOpen)
        staleDisappear.send(.disappeared)
        expect(staleDisappear.phase, .opening, "stale disappearance cannot cancel new opening")

        print("ImmersiveSessionStateTests: PASS")
    }
}
```

- [x] **Step 2: Run the test to verify RED**

Run:

```bash
xcrun swiftc "Barrier City/ImmersiveSessionState.swift" Tests/ImmersiveSessionStateTests.swift -o /tmp/immersive-session-state-tests
```

Expected: FAIL because the production state file does not exist.

- [x] **Step 3: Implement the minimal state machine**

Create `Barrier City/ImmersiveSessionState.swift`:

```swift
enum ImmersiveSessionPhase: Equatable {
    case closed
    case opening
    case open
    case closing
}

enum ImmersiveSessionEvent: Equatable {
    case beginOpen
    case openSucceeded
    case openFailed
    case beginClose
    case closeSucceeded
    case appeared
    case disappeared
}

struct ImmersiveSessionState: Equatable {
    private(set) var phase: ImmersiveSessionPhase = .closed

    var isImmersive: Bool {
        phase == .open || phase == .closing
    }

    var isTransitioning: Bool {
        phase == .opening || phase == .closing
    }

    var controlTitle: String {
        switch phase {
        case .closed: "체험 시작"
        case .opening: "여는 중…"
        case .open: "체험 종료"
        case .closing: "종료 중…"
        }
    }

    mutating func send(_ event: ImmersiveSessionEvent) {
        switch (phase, event) {
        case (.closed, .beginOpen):
            phase = .opening
        case (.opening, .openSucceeded), (.opening, .appeared), (.closed, .appeared):
            phase = .open
        case (.opening, .openFailed):
            phase = .closed
        case (.open, .beginClose):
            phase = .closing
        case (.closing, .closeSucceeded), (.open, .disappeared), (.closing, .disappeared):
            phase = .closed
        default:
            break
        }
    }
}
```

- [x] **Step 4: Run the focused test to verify GREEN**

Run the Step 2 command, then:

```bash
/tmp/immersive-session-state-tests
```

Expected: `ImmersiveSessionStateTests: PASS`.

### Task 2: Connect Async Open, Dismiss, and View Lifecycle

**Files:**
- Modify: `Barrier City/AppModel.swift:52-58`
- Modify: `Barrier City/ControlPanelView.swift:9-12,85-120,228`
- Modify: `Barrier City/ImmersiveView.swift:197-207`

**Interfaces:**
- Consumes: `ImmersiveSessionState` from Task 1 and SwiftUI `openImmersiveSpace`/`dismissImmersiveSpace`.
- Produces: `AppModel.updateImmersiveSession(_:)` and a computed compatibility property `AppModel.isImmersive`.

- [x] **Step 1: Replace the mutable Boolean with shared state**

In `AppModel.swift`, replace `var isImmersive = false` with:

```swift
private(set) var immersiveSessionState = ImmersiveSessionState()

var isImmersive: Bool { immersiveSessionState.isImmersive }

func updateImmersiveSession(_ event: ImmersiveSessionEvent) {
    immersiveSessionState.send(event)
}
```

- [x] **Step 2: Drive state from control-window operations**

Remove `ControlPanelView.isImmersiveTransitioning`. Use
`model.immersiveSessionState.phase` to choose the start or stop action and use
`model.immersiveSessionState.controlTitle` for the label.

The start task sends `.beginOpen` before awaiting `openSpace`. It sends
`.openSucceeded` for `.opened` and `.openFailed` for every failure result.

The stop task sends `.beginClose` before awaiting `dismissSpace` and sends
`.closeSucceeded` after the await returns.

Replace the view-level disabled condition with:

```swift
.disabled(model.immersiveSessionState.isTransitioning)
```

- [x] **Step 3: Reconcile view lifecycle callbacks**

In `ImmersiveView`:

```swift
.onAppear {
    model.updateImmersiveSession(.appeared)
    AppModel.current = model
}
.onDisappear {
    QuestSetup.stop()
    InteractionModel.shared.endImmersiveSession()
    model.updateImmersiveSession(.disappeared)
    model.npcClerk.resetForOutdoor()
    handTracker.stop(model: model)
}
```

- [x] **Step 4: Run all focused standalone tests**

Compile and run `ImmersiveSessionStateTests`, `HandTrackingLifecycleContractTests`, `OutdoorSessionStartTests`,
`GuideFlowStateTests`, `QuestModelOutcomeTests`, `SceneTransitionSessionTests`,
`LoopingGuidePlaybackContractTests`, and `InteractionFlowRegressionTests` with
their existing compile lists.

Expected: all seven executables print `PASS`.

- [x] **Step 5: Run package and app verification**

Run:

```bash
cd Packages/DialogueKit && swift test
xcodebuild -scheme "Barrier City" -project "Barrier City.xcodeproj" -destination "generic/platform=visionOS Simulator" -derivedDataPath /tmp/barrier-city-lifecycle-pr-validation CODE_SIGNING_ALLOWED=NO build
```

Expected: 54 DialogueKit tests pass with zero failures and Xcode reports `** BUILD SUCCEEDED **`.

The first independent review identified unversioned callback races. Add a
generation to each session, store it in `ImmersiveView`, reject older async
results, and guard all `onDisappear` teardown. Extend the focused test through
`closeSucceeded → beginOpen → appeared → stale disappeared` and verify the
replacement remains open. Re-run all checks above after this hardening.

The second review identified that a stale view still owns a local ARKit session
even though it must not clear replacement-session model state. Split tracker
shutdown into unconditional `stopSession()` and generation-guarded
`clearModelInput(model:)`, add a source contract test for their ordering, and
re-run the eight standalone checks plus Simulator build/run.

- [x] **Step 6: Review and commit**

Run `git diff --check`, review the full diff, and commit the production files,
tests, design, and this plan with:

```bash
git commit -m "fix(app): restore immersive restart flow"
```

- [ ] **Step 7: Manual acceptance**

1. Start the experience and confirm the button becomes `체험 종료`.
2. Select exit and confirm `종료 중…` changes to `체험 시작`.
3. Start the experience again and confirm the immersive space opens at the
   outdoor origin facing the cafe.
4. Exit again and confirm the start action returns a second time.
