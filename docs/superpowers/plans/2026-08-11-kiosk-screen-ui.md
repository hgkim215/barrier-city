# Indoor Kiosk Screen UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render an always-on SwiftUI cafe menu on Indoor's real `Screen/Plane`, turn gaze-pinch or a deliberate hand reach into one accessibility-barrier card, and continue through the existing Mission 3/NPC flow.

**Architecture:** Keep interaction decisions in pure Swift state machines, wrap them in `InteractionModel`, and let the existing `HandTrackingManager` feed screen-local hand samples without starting another ARKit provider. A RealityKit presenter attaches the existing `kioskScreen` attachment to `Screen/Plane`, with the current world-fixed billboard retained only as a placement fallback.

**Tech Stack:** Swift 5, SwiftUI, Observation, RealityKit, ARKit hand tracking, simd, standalone `swiftc` regression executables, visionOS Simulator build

## Global Constraints

- The menu is visible for the entire Indoor scene and accepts input only while near the kiosk, Mission 2 is active, and the guide is unlocked.
- The barrier copy is exactly `손이 닿지 않습니다`, `앉은 자세에서는 이 메뉴를 선택할 수 없습니다.`, and `직원에게 도움 받기`.
- Gaze-pinch and direct hand reach converge on one idempotent kiosk-attempt path.
- Hand defaults are front distance `0.08...0.65m`, horizontal margin `0.12m`, movement `0.08m` within `0.45s`, dwell `0.20s`, cooldown `1.0s`, and stale timeout `0.25s`.
- The help action emits `.kioskFailed` once, leaves the menu visible, and locks kiosk input until immersive-session reset.
- Missing `Screen/Plane` or invalid bounds use the current world-fixed billboard; a missing attachment fail-opens Mission 2 without introducing a second HUD.
- Do not implement a real cart, payment, completed order, remote menu API, or external cafe branding/assets.
- Do not modify `Screen.usdz`, `Indoor.usda`, NPC dialogue/animation/movement, or user-owned Reality Composer Pro workspace metadata.
- Vision Pro hand tracking and spatial calibration remain explicit real-device acceptance checks; Simulator/build success is not device proof.

---

## File Structure

- Create `Barrier City/Interaction/KioskReachAttemptDetector.swift`: pure per-hand reach state machine and tuning values.
- Create `Barrier City/Interaction/KioskInteractionState.swift`: pure menu/input/barrier/help state and idempotency.
- Create `Barrier City/Interaction/KioskScreenLayout.swift`: pure aspect-fit scale calculation.
- Create `Barrier City/Interaction/KioskScreenPresenter.swift`: Screen lookup, attachment sizing/placement, and fallback result.
- Create `Tests/KioskReachAttemptDetectorTests.swift`: detector thresholds, stale reset, and cooldown coverage.
- Create `Tests/KioskInteractionStateTests.swift`: visibility, gating, dedupe, help, and reset coverage.
- Create `Tests/KioskScreenLayoutTests.swift`: pure aspect-fit scale validation and invalid-bounds fallback coverage.
- Modify `Barrier City/Interaction/InteractionModel.swift`: own kiosk state/detectors, expose view properties, convert world hand points into Screen-local samples.
- Modify `Barrier City/Interaction/InteractionSetup.swift`: keep Screen-attached menu always visible, retain billboard fallback, update kiosk context, and fail-open missing attachment.
- Modify `Barrier City/Interaction/SceneSwitcher.swift`: install the attachment on Indoor `Screen/Plane` and reset kiosk session state.
- Modify `Barrier City/Interaction/KioskOrderView.swift`: replace the text panel with the branded 9:16 menu and bottom barrier card.
- Modify `Barrier City/HandTrackingManager.swift`: feed the existing middle-knuckle world sample to the kiosk detector for each hand.
- Modify `Tests/InteractionFlowRegressionTests.swift`: cover the existing Mission 2 to Mission 3 regression through the new state API.

### Task 1: Pure Hand-Reach Detection

**Files:**
- Create: `Barrier City/Interaction/KioskReachAttemptDetector.swift`
- Create: `Tests/KioskReachAttemptDetectorTests.swift`

**Interfaces:**
- Consumes: Screen-local `SIMD3<Float>`, monotonically increasing `TimeInterval`, and `isTracked`.
- Produces: `KioskHandSide`, `KioskReachTuning`, and `KioskReachAttemptDetector.sample(position:timestamp:isTracked:halfWidth:halfHeight:) -> Bool`.

- [ ] **Step 1: Write the failing detector tests**

Create a standalone executable that uses the exact defaults and verifies: a `z` approach and upward reach trigger after dwell; out-of-bounds, stationary, and low-wheel samples do not; a `0.26s` gap resets; and the `1.0s` cooldown deduplicates before allowing a later attempt.

```swift
var detector = KioskReachAttemptDetector()
let halfWidth: Float = 0.15
let halfHeight: Float = 0.26

expectFalse(detector.sample(position: [0, 0, 0.55], timestamp: 0.00,
                            isTracked: true, halfWidth: halfWidth, halfHeight: halfHeight), "start")
expectFalse(detector.sample(position: [0, 0, 0.45], timestamp: 0.20,
                            isTracked: true, halfWidth: halfWidth, halfHeight: halfHeight), "movement arms")
expectTrue(detector.sample(position: [0, 0, 0.44], timestamp: 0.41,
                           isTracked: true, halfWidth: halfWidth, halfHeight: halfHeight), "dwell fires")
expectFalse(detector.sample(position: [0, 0, 0.32], timestamp: 0.50,
                            isTracked: true, halfWidth: halfWidth, halfHeight: halfHeight), "cooldown")
```

- [ ] **Step 2: Run the detector test to verify RED**

Run:

```bash
xcrun swiftc "Barrier City/Interaction/KioskReachAttemptDetector.swift" Tests/KioskReachAttemptDetectorTests.swift -o /tmp/kiosk-reach-tests
```

Expected: FAIL because the production file and symbols do not exist.

- [ ] **Step 3: Implement the detector minimally**

Use one origin window, one armed timestamp, last-sample time, and cooldown deadline. Front-facing Screen space is `+Z`, so approach is `origin.z - current.z`; upward movement is `current.y - origin.y`.

```swift
enum KioskHandSide: Hashable { case left, right }

enum KioskReachTuning {
    static let frontRange: ClosedRange<Float> = 0.08...0.65
    static let horizontalMargin: Float = 0.12
    static let minimumMovement: Float = 0.08
    static let movementWindow: TimeInterval = 0.45
    static let dwellDuration: TimeInterval = 0.20
    static let cooldownDuration: TimeInterval = 1.0
    static let staleTimeout: TimeInterval = 0.25
}

struct KioskReachAttemptDetector {
    private var origin: (position: SIMD3<Float>, time: TimeInterval)?
    private var armedAt: TimeInterval?
    private var lastSampleTime: TimeInterval?
    private var cooldownUntil: TimeInterval = -.infinity

    mutating func reset() {
        origin = nil
        armedAt = nil
        lastSampleTime = nil
        cooldownUntil = -.infinity
    }

    mutating func sample(position: SIMD3<Float>, timestamp: TimeInterval,
                         isTracked: Bool, halfWidth: Float, halfHeight: Float) -> Bool {
        if !isTracked || (lastSampleTime.map { timestamp - $0 > KioskReachTuning.staleTimeout } ?? false) {
            origin = nil; armedAt = nil
        }
        lastSampleTime = timestamp
        guard isTracked, timestamp >= cooldownUntil,
              KioskReachTuning.frontRange.contains(position.z),
              abs(position.x) <= halfWidth + KioskReachTuning.horizontalMargin,
              abs(position.y) <= halfHeight + KioskReachTuning.horizontalMargin else {
            origin = nil; armedAt = nil; return false
        }
        guard let start = origin else { origin = (position, timestamp); return false }
        if timestamp - start.time > KioskReachTuning.movementWindow {
            origin = (position, timestamp); armedAt = nil; return false
        }
        let moved = start.position.z - position.z >= KioskReachTuning.minimumMovement
            || position.y - start.position.y >= KioskReachTuning.minimumMovement
        if moved, armedAt == nil { armedAt = timestamp }
        guard let armedAt, timestamp - armedAt >= KioskReachTuning.dwellDuration else { return false }
        cooldownUntil = timestamp + KioskReachTuning.cooldownDuration
        origin = nil; self.armedAt = nil
        return true
    }
}
```

- [ ] **Step 4: Run the detector tests to verify GREEN**

Run the compile command, then `/tmp/kiosk-reach-tests`. Expected: `KioskReachAttemptDetectorTests: PASS`.

- [ ] **Step 5: Commit the detector slice**

```bash
git add "Barrier City/Interaction/KioskReachAttemptDetector.swift" Tests/KioskReachAttemptDetectorTests.swift
git commit -m "feat: 키오스크 손 뻗기 감지기 추가"
```

### Task 2: Pure Kiosk Interaction State

**Files:**
- Create: `Barrier City/Interaction/KioskInteractionState.swift`
- Create: `Tests/KioskInteractionStateTests.swift`
- Modify: `Barrier City/Interaction/InteractionModel.swift`
- Modify: `Tests/InteractionFlowRegressionTests.swift`

**Interfaces:**
- Consumes: Indoor/near/Mission 2/guide-lock context and `KioskAttemptSource`.
- Produces: `KioskInteractionState.menuVisible`, `.inputEnabled`, `.barrierVisible`, `.attempt(_:) -> Bool`, `.requestStaffHelp() -> Bool`, and `.reset()`; `InteractionModel.attemptKioskUse(_:)`, `.requestKioskStaffHelp()`, `.updateKioskContext(...)`, and `.resetKioskSession()`.

- [ ] **Step 1: Write failing state tests**

Test the exact matrix below in `Tests/KioskInteractionStateTests.swift`:

```swift
var state = KioskInteractionState()
state.updateContext(isIndoor: true, isNear: false, isMissionTwoActive: true, isGuideLocked: false)
expect(state.menuVisible, true, "Indoor keeps menu visible")
expect(state.inputEnabled, false, "far kiosk is display-only")
expect(state.attempt(.gazePinch), false, "far attempt ignored")
state.updateContext(isIndoor: true, isNear: true, isMissionTwoActive: true, isGuideLocked: false)
expect(state.attempt(.gazePinch), true, "first attempt opens barrier")
expect(state.attempt(.handReach), false, "second input deduplicates")
expect(state.requestStaffHelp(), true, "help emits once")
expect(state.requestStaffHelp(), false, "help deduplicates")
expect(state.inputEnabled, false, "help locks session")
state.reset()
expect(state.menuVisible, false, "session reset clears indoor state")
```

- [ ] **Step 2: Run the state test to verify RED**

```bash
xcrun swiftc "Barrier City/Interaction/KioskInteractionState.swift" Tests/KioskInteractionStateTests.swift -o /tmp/kiosk-state-tests
```

Expected: FAIL because the production state does not exist.

- [ ] **Step 3: Implement the pure state**

```swift
enum KioskAttemptSource: Equatable { case gazePinch, handReach }

struct KioskInteractionState: Equatable {
    private(set) var isIndoor = false
    private(set) var isNear = false
    private(set) var isMissionTwoActive = false
    private(set) var isGuideLocked = true
    private(set) var barrierVisible = false
    private(set) var helpRequested = false

    var menuVisible: Bool { isIndoor }
    var inputEnabled: Bool {
        isIndoor && isNear && isMissionTwoActive && !isGuideLocked && !barrierVisible && !helpRequested
    }
    mutating func updateContext(isIndoor: Bool, isNear: Bool,
                                isMissionTwoActive: Bool, isGuideLocked: Bool) {
        self.isIndoor = isIndoor; self.isNear = isNear
        self.isMissionTwoActive = isMissionTwoActive; self.isGuideLocked = isGuideLocked
    }
    mutating func attempt(_ source: KioskAttemptSource) -> Bool {
        guard inputEnabled else { return false }
        barrierVisible = true; return true
    }
    mutating func requestStaffHelp() -> Bool {
        guard barrierVisible, !helpRequested else { return false }
        barrierVisible = false; helpRequested = true; return true
    }
    mutating func reset() { self = KioskInteractionState() }
}
```

- [ ] **Step 4: Wrap the state and per-hand detectors in `InteractionModel`**

Add `kioskState`, `[KioskHandSide: KioskReachAttemptDetector]`, `kioskScreenPlane`, and `kioskScreenHalfSize`. Expose computed view properties, reset them in `beginImmersiveSession`/`endImmersiveSession`, and implement world-to-plane conversion:

```swift
func processKioskHandSample(side: KioskHandSide, worldPosition: SIMD3<Float>,
                            timestamp: TimeInterval, isTracked: Bool) {
    guard kioskState.inputEnabled, let plane = kioskScreenPlane else {
        kioskReachDetectors[side]?.reset(); return
    }
    let local = plane.convert(position: worldPosition, from: nil)
    if kioskReachDetectors[side, default: .init()].sample(
        position: local, timestamp: timestamp, isTracked: isTracked,
        halfWidth: kioskScreenHalfSize.x, halfHeight: kioskScreenHalfSize.y) {
        _ = attemptKioskUse(.handReach)
    }
}
```

- [ ] **Step 5: Update the interaction regression test and verify GREEN**

Replace `kioskTooHighShown` assertions with the new state API, then run:

```bash
xcrun swiftc "Barrier City/Interaction/KioskInteractionState.swift" Tests/KioskInteractionStateTests.swift -o /tmp/kiosk-state-tests
/tmp/kiosk-state-tests
```

Expected: `KioskInteractionStateTests: PASS`.

- [ ] **Step 6: Commit the state slice**

```bash
git add "Barrier City/Interaction/KioskInteractionState.swift" "Barrier City/Interaction/InteractionModel.swift" Tests/KioskInteractionStateTests.swift Tests/InteractionFlowRegressionTests.swift
git commit -m "refactor: 키오스크 상호작용 상태 통합"
```

### Task 3: Attach SwiftUI to the Real Screen Plane

**Files:**
- Create: `Barrier City/Interaction/KioskScreenLayout.swift`
- Create: `Barrier City/Interaction/KioskScreenPresenter.swift`
- Create: `Tests/KioskScreenLayoutTests.swift`
- Modify: `Barrier City/Interaction/SceneSwitcher.swift`
- Modify: `Barrier City/Interaction/InteractionSetup.swift`

**Interfaces:**
- Consumes: Indoor entity, `kioskScreen` attachment, and `worldRoot`.
- Produces: `KioskScreenLayout.uniformScale(planeSize:attachmentSize:fill:) -> Float?`, `KioskScreenPlacement`, and `KioskScreenPresenter.install(attachment:in:worldRoot:) -> KioskScreenPlacement`.

- [ ] **Step 1: Write failing layout tests**

Verify that `0.30×0.52m` and `0.60×1.00m` yield `0.49` at fill `0.98`, a width-limited case uses width, and zero/NaN bounds return `nil`.

```swift
expectNear(KioskScreenLayout.uniformScale(planeSize: [0.30, 0.52],
                                          attachmentSize: [0.60, 1.00], fill: 0.98)!,
           0.49, "height-limited fit")
expectNil(KioskScreenLayout.uniformScale(planeSize: [0, 0.52],
                                         attachmentSize: [0.60, 1.00], fill: 0.98),
          "invalid plane bounds")
```

- [ ] **Step 2: Run the layout test to verify RED**

```bash
xcrun swiftc "Barrier City/Interaction/KioskScreenLayout.swift" Tests/KioskScreenLayoutTests.swift -o /tmp/kiosk-layout-tests
```

Expected: FAIL because the pure layout file and symbol do not exist.

- [ ] **Step 3: Implement layout and placement**

`KioskScreenPresenter.install` must find named `Screen`, then its descendant `Plane`; validate both visual bounds; remove the attachment from its old parent; attach it to `Plane`; place it at the plane bounds center plus `max.z + 0.002`; apply `KioskScreenTuning.faceRotation` (identity); and return the plane plus half-size. Any lookup/bounds failure returns `.billboardFallback` after reattaching to `worldRoot`.

```swift
enum KioskScreenPlacement {
    case attached(plane: Entity, halfSize: SIMD2<Float>)
    case billboardFallback
}

enum KioskScreenTuning {
    static let fill: Float = 0.98
    static let surfaceOffset: Float = 0.002
    static let faceRotation = simd_quatf(angle: 0, axis: [0, 1, 0])
}
```

- [ ] **Step 4: Integrate placement and always-on visibility**

After `SceneSwitcher` installs the Indoor map and registers its kiosk trigger, call the presenter with `im.kioskPanelEntity`. Store the returned plane/half-size in `InteractionModel`. In `InteractionSetup.tick`, update kiosk context from `scene`, active kiosk trigger, `GuideFlowModel.phase == .missionActive(index: 1)`, and guide lock. `updatePanel` enables an attached menu whenever `scene == .indoor`; only `.billboardFallback` uses the existing proximity billboard.

For a missing attachment, once Mission 2 is active, set a one-shot `kioskFailOpenSent` flag and call `GuideFlowModel.shared.handleQuestEvent(.kioskFailed)` so the route cannot deadlock.

- [ ] **Step 5: Run layout and interaction tests**

Run `/tmp/kiosk-layout-tests`, `/tmp/kiosk-state-tests`, and the updated interaction regression executable. Expected: all print `PASS`.

- [ ] **Step 6: Commit the placement slice**

```bash
git add "Barrier City/Interaction/KioskScreenLayout.swift" "Barrier City/Interaction/KioskScreenPresenter.swift" "Barrier City/Interaction/SceneSwitcher.swift" "Barrier City/Interaction/InteractionSetup.swift" Tests/KioskScreenLayoutTests.swift
git commit -m "feat: 키오스크 UI를 Screen 평면에 배치"
```

### Task 4: Branded Menu and Barrier Card

**Files:**
- Modify: `Barrier City/Interaction/KioskOrderView.swift`

**Interfaces:**
- Consumes: `InteractionModel.kioskMenuVisible`, `.kioskInputEnabled`, `.kioskBarrierVisible`, `.attemptKioskUse(.gazePinch)`, and `.requestKioskStaffHelp()`.
- Produces: a fixed 540×960 9:16 SwiftUI canvas with `BARRIER CAFE`, four category tabs, a 3-column static menu, decorative order strip, and bottom feedback card.

- [ ] **Step 1: Confirm the tested view-state boundary is RED**

Before changing the view, run `KioskInteractionStateTests` from Task 2 while its menu attempt, barrier visibility, and one-shot help assertions are still failing. These are the consumer-visible behaviors the SwiftUI controls must drive; exact display copy is an approved product decision and is verified through rendered acceptance rather than a brittle source grep.

- [ ] **Step 2: Implement the menu canvas**

Define a local `CafeMenuItem` array (아메리카노, 카페라떼, 카페모카, 에스프레소, 아이스티, 핫초코, 자몽티, 말차라떼, 복숭아티), warm brown/orange colors, and reusable `menuCard`. Each enabled card invokes `_ = im.attemptKioskUse(.gazePinch)`; `.disabled(!im.kioskInputEnabled)` preserves the always-on display. Use only `cup.and.saucer.fill`, `mug.fill`, or SwiftUI shapes—no attached screenshot or third-party logo.

- [ ] **Step 3: Implement the bottom barrier overlay**

When `im.kioskBarrierVisible`, overlay a high-contrast bottom card with the exact title, description, and button. The button calls `requestKioskStaffHelp()` and emits `.kioskFailed` only when it returns `true`.

```swift
Button("직원에게 도움 받기") {
    if im.requestKioskStaffHelp() {
        GuideFlowModel.shared.handleQuestEvent(.kioskFailed)
    }
}
```

- [ ] **Step 4: Run state tests and build**

Expected: `KioskInteractionStateTests: PASS`, and the visionOS compile in Task 6 reports no SwiftUI API/type errors. Simulator acceptance checks compare the rendered title, description, and action labels to the approved copy.

- [ ] **Step 5: Commit the UI slice**

```bash
git add "Barrier City/Interaction/KioskOrderView.swift"
git commit -m "feat: 카페 키오스크 메뉴와 장벽 카드 구현"
```

### Task 5: Feed Existing Hand Tracking into Kiosk Attempts

**Files:**
- Modify: `Barrier City/HandTrackingManager.swift`
- Modify: `Tests/HandTrackingLifecycleContractTests.swift`

**Interfaces:**
- Consumes: existing `gripWorldPosition(_:)`, `HandAnchor.Chirality`, `anchor.isTracked`, and `InteractionModel.processKioskHandSample`.
- Produces: one kiosk sample per existing anchor update without a second `ARKitSession` or `HandTrackingProvider`.

- [ ] **Step 1: Confirm detector integration behavior is RED**

Run the detector and state tests before the hand integration exists: detector attempts are produced and accepted in isolation, but no live hand anchor path feeds them yet. The integration's observable proof is the app compiling with the real ARKit types and the Vision Pro acceptance check; do not add a source-string change detector.

- [ ] **Step 2: Run the contract test to verify RED**

```bash
xcrun swiftc -parse-as-library Tests/HandTrackingLifecycleContractTests.swift -o /tmp/hand-lifecycle-contract-tests
/tmp/hand-lifecycle-contract-tests "Barrier City/ImmersiveView.swift" "Barrier City/HandTrackingManager.swift"
```

Expected: the existing lifecycle contract remains `PASS`; the new end-to-end hand behavior remains unavailable until Step 3.

- [ ] **Step 3: Forward the existing hand sample**

Immediately after computing `gripPos`, map chirality without leaking ARKit types into the detector and forward a monotonic timestamp. Do this before wheel/fist branching so both control modes retain kiosk reach behavior.

```swift
let kioskSide: KioskHandSide = chirality == .left ? .left : .right
InteractionModel.shared.processKioskHandSample(
    side: kioskSide,
    worldPosition: gripPos,
    timestamp: ProcessInfo.processInfo.systemUptime,
    isTracked: anchor.isTracked)
```

If guide/input context is disabled, `InteractionModel` resets that hand's detector and returns; wheel logic remains unchanged.

- [ ] **Step 4: Run detector, state, and hand lifecycle tests**

Expected: all three focused executables print `PASS`.

- [ ] **Step 5: Commit the hand integration slice**

```bash
git add "Barrier City/HandTrackingManager.swift" Tests/HandTrackingLifecycleContractTests.swift
git commit -m "feat: 손 뻗기를 키오스크 시도로 연결"
```

### Task 6: Full Regression, Build, and Handoff

**Files:**
- Modify only if verification exposes a defect: files already listed in Tasks 1–5.

**Interfaces:**
- Consumes: all completed kiosk slices and existing regression suites.
- Produces: dated automated evidence, a pushed feature branch, and a Korean PR targeting `develop`.

- [ ] **Step 1: Run every standalone regression executable**

Run the established commands from the prior plans plus the three new pure tests. Required success lines include all existing test names and the three new `Kiosk...Tests: PASS` lines.

- [ ] **Step 2: Run DialogueKit tests**

```bash
swift test --package-path Packages/DialogueKit
```

Expected: 54 tests, 0 failures (or report the current discovered count if the suite has legitimately changed).

- [ ] **Step 3: Build the visionOS app**

```bash
xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" -destination 'generic/platform=visionOS Simulator' -derivedDataPath /tmp/barrier-city-kiosk-derived CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Perform available Simulator acceptance checks**

Verify Indoor entry, Screen-aligned always-on menu, near-only gaze/pinch, one barrier card, Mission 3 transition, NPC dialogue entry, and immersive re-entry reset. Record any parts the environment cannot automate; do not claim hand-reach verification without Vision Pro.

- [ ] **Step 5: Review scope and staged diff**

Run `git diff --check`, `git status --short`, and `git diff develop...HEAD --stat`. Confirm no `Package.realitycomposerpro/PluginData`, `SceneMetadataList.json`, or `.rcuserdata` file is staged or committed.

- [ ] **Step 6: Commit any verification-only fixes**

Stage only explicit feature/test files and use a narrow Korean commit message. Re-run the failing command and the full relevant suite before proceeding.

- [ ] **Step 7: Push and open the PR**

```bash
git push -u origin codex/kiosk-screen-ui
gh pr create --base develop --head codex/kiosk-screen-ui --title "feat: 실내 키오스크 Screen UI와 접근성 장벽 체험 구현" --body-file /tmp/kiosk-screen-pr.md
```

The Korean PR body must summarize the real Screen attachment, dual input path, Mission 3 reuse, automated evidence, and the remaining Vision Pro checks (hand threshold, z-fighting/front-face, seated readability). Do not describe real-device checks as completed.
