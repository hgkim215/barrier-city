# Kiosk Category Barrier Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the upside-down kiosk attachment, add a high-contrast category-driven cafe menu, and make the inaccessible `기타` tab lead to the existing staff-order mission.

**Architecture:** Extend the pure `KioskInteractionState` into the single source of truth for category, menu selection, barrier, and help-lock state. Route SwiftUI actions through `InteractionModel`, and isolate the spatial correction as a pure π-radian contract consumed by `KioskScreenPresenter`.

**Tech Stack:** Swift 5, SwiftUI, Observation, RealityKit, simd, standalone `swiftc` regressions, visionOS Simulator build

## Global Constraints

- The kiosk canvas remains exactly 540×960 points.
- Category order is exactly `베스트`, `커피`, `티`, `에이드`, `논커피`, `디카페인`, `기타`, `전체` in a 4×2 grid.
- General categories switch normally; `기타` keeps the previous selection and opens the barrier.
- Barrier copy is exactly `높아서 선택할 수 없습니다` and `앉은 자세에서는 기타 카테고리에 손이 닿지 않습니다. 카페 직원에게 직접 주문해 보세요.`.
- Barrier actions are `직원에게 직접 주문하기` and `닫기`.
- Mission progression occurs only after the primary action and emits `kioskFailed` once.
- `레인보우 스무디` is the first `기타` catalog item, but Mission 2 cannot enter that category.
- Every filtered category has at least six deterministic local menu items; `베스트` and `전체` show nine.
- The attached screen rotates π radians around local Z; position, scale, and surface-normal behavior do not change.
- Do not modify `Screen.usdz`, `Indoor.usda`, NPC behavior, payment behavior, or external APIs.
- Do not stage `Barrier City.xcodeproj/project.pbxproj` or `docs/design-assets/`.
- Preserve the door prompt, safe spawn, wheelchair movement, scene switching, and kiosk fail-open behavior.
- Automated checks do not replace the user's direct spatial acceptance.

---

## File Structure

- Modify `Barrier City/Interaction/KioskInteractionState.swift`: category, menu, barrier, dismiss, and help state.
- Modify `Barrier City/Interaction/InteractionModel.swift`: observable wrappers and input routing.
- Modify `Tests/KioskInteractionStateTests.swift`: pure state matrix.
- Modify `Tests/InteractionFlowRegressionTests.swift`: Mission 2 → barrier → Mission 3 integration.
- Modify `Barrier City/Interaction/KioskScreenLayout.swift`: pure orientation constant.
- Modify `Barrier City/Interaction/KioskScreenPresenter.swift`: local Z-axis screen correction.
- Modify `Tests/KioskScreenLayoutTests.swift`: rotation regression.
- Modify `Barrier City/Interaction/KioskOrderView.swift`: approved high-contrast UI.

### Task 1: Model Category Selection and the Accessibility Barrier

**Files:**
- Modify: `Tests/KioskInteractionStateTests.swift`
- Modify: `Barrier City/Interaction/KioskInteractionState.swift`
- Modify: `Barrier City/Interaction/InteractionModel.swift`
- Modify: `Tests/InteractionFlowRegressionTests.swift`

**Interfaces:**
- Consumes: kiosk context gating, `KioskAttemptSource`, and existing one-shot staff-help flow.
- Produces: `KioskCategory`, `KioskCategorySelectionResult`, `selectedCategory`, `selectedMenuID`, `selectCategory(_:source:)`, `selectMenu(id:)`, `dismissBarrier()`, and `attemptRestrictedCategory(_:)`.

- [ ] **Step 1: Write failing category-state tests**

Replace the generic attempt test with:

```swift
private static func generalCategoriesSwitchAndMenusSelect() {
    var state = enabledState()
    expect(state.selectedCategory, .best, "best is selected initially")
    expect(state.selectCategory(.coffee, source: .gazePinch), .selected, "coffee switches")
    expect(state.selectedCategory, .coffee, "coffee remains selected")
    expect(state.barrierVisible, false, "general category stays usable")
    expect(state.selectMenu(id: "cafe-latte"), true, "menu can be selected")
    expect(state.selectedMenuID, "cafe-latte", "menu id is stored")
}

private static func otherCategoryBlocksWithoutSelecting() {
    var state = enabledState()
    _ = state.selectCategory(.coffee, source: .gazePinch)
    expect(state.selectCategory(.other, source: .gazePinch), .blocked, "other is blocked")
    expect(state.selectedCategory, .coffee, "previous category remains")
    expect(state.barrierVisible, true, "barrier opens")
    expect(state.attemptRestrictedCategory(.handReach), false, "second source deduplicates")
}

private static func dismissKeepsMissionRetryable() {
    var state = enabledState()
    _ = state.selectCategory(.other, source: .gazePinch)
    expect(state.dismissBarrier(), true, "barrier closes")
    expect(state.helpRequested, false, "dismiss does not request help")
    expect(state.inputEnabled, true, "retry is enabled")
}
```

Update help/reset tests to enter through `.other`. Assert reset restores `.best` and clears `selectedMenuID`.

- [ ] **Step 2: Run the focused test to verify RED**

```bash
xcrun swiftc \
  "Barrier City/Interaction/KioskInteractionState.swift" \
  Tests/KioskInteractionStateTests.swift \
  -o /tmp/kiosk-interaction-state-tests
/tmp/kiosk-interaction-state-tests
```

Expected: compile failure because the category APIs do not exist.

- [ ] **Step 3: Implement the pure state APIs**

Add:

```swift
enum KioskCategory: String, CaseIterable, Hashable {
    case best, coffee, tea, ade, nonCoffee, decaf, other, all
}

enum KioskCategorySelectionResult: Equatable {
    case ignored, selected, blocked
}
```

Add `private(set) var selectedCategory: KioskCategory = .best` and `private(set) var selectedMenuID: String?`, then implement:

```swift
mutating func selectCategory(
    _ category: KioskCategory,
    source: KioskAttemptSource
) -> KioskCategorySelectionResult {
    guard inputEnabled else { return .ignored }
    if category == .other {
        barrierVisible = true
        return .blocked
    }
    selectedCategory = category
    selectedMenuID = nil
    return .selected
}

mutating func attemptRestrictedCategory(_ source: KioskAttemptSource) -> Bool {
    guard inputEnabled else { return false }
    barrierVisible = true
    return true
}

mutating func selectMenu(id: String) -> Bool {
    guard inputEnabled, selectedCategory != .other else { return false }
    selectedMenuID = id
    return true
}

mutating func dismissBarrier() -> Bool {
    guard barrierVisible, !helpRequested else { return false }
    barrierVisible = false
    return true
}
```

Keep `requestStaffHelp()` and memberwise `reset()` semantics.

- [ ] **Step 4: Route the state through InteractionModel**

Expose:

```swift
var kioskSelectedCategory: KioskCategory { kioskState.selectedCategory }
var kioskSelectedMenuID: String? { kioskState.selectedMenuID }

func selectKioskCategory(
    _ category: KioskCategory,
    source: KioskAttemptSource = .gazePinch
) -> KioskCategorySelectionResult {
    kioskState.selectCategory(category, source: source)
}

func selectKioskMenu(id: String) -> Bool { kioskState.selectMenu(id: id) }
func attemptRestrictedKioskCategory(_ source: KioskAttemptSource) -> Bool {
    kioskState.attemptRestrictedCategory(source)
}
func dismissKioskBarrier() -> Bool { kioskState.dismissBarrier() }
```

Route a detected hand reach to `attemptRestrictedKioskCategory(.handReach)`.

- [ ] **Step 5: Update the integration regression**

Replace the generic kiosk attempt with:

```swift
expect(interactions.selectKioskCategory(.coffee), .selected, "general category switches")
expect(interactions.kioskSelectedCategory, .coffee, "coffee remains selected")
expect(interactions.kioskBarrierVisible, false, "general category stays usable")
expect(interactions.selectKioskCategory(.other), .blocked, "other exposes barrier")
expect(interactions.kioskSelectedCategory, .coffee, "blocked tab does not select")
expect(interactions.kioskBarrierVisible, true, "other opens barrier")
```

Keep the existing one-shot help, Mission 3, input-lock, and reset assertions. Add reset assertions for `.best` and nil menu selection.

- [ ] **Step 6: Run focused state and integration tests to verify GREEN**

Re-run Step 2, then:

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

Expected: both executables print PASS.

- [ ] **Step 7: Commit the state slice**

```bash
git add "Barrier City/Interaction/KioskInteractionState.swift" \
  "Barrier City/Interaction/InteractionModel.swift" \
  Tests/KioskInteractionStateTests.swift \
  Tests/InteractionFlowRegressionTests.swift
git commit -m "feat: model inaccessible kiosk category"
```

### Task 2: Correct the Attachment Orientation

**Files:**
- Modify: `Tests/KioskScreenLayoutTests.swift`
- Modify: `Barrier City/Interaction/KioskScreenLayout.swift`
- Modify: `Barrier City/Interaction/KioskScreenPresenter.swift`

**Interfaces:**
- Consumes: existing Screen/Plane attachment placement.
- Produces: `KioskScreenLayout.faceRotationRadians == Float.pi`, used as a local Z-axis quaternion.

- [ ] **Step 1: Add a failing rotation test**

```swift
let rotation = KioskScreenLayout.faceRotationRadians
expectNear(rotation, .pi, "screen correction is a half turn")
expectNear(cosf(rotation), -1, "half turn reverses local X and Y")
expectNear(sinf(rotation), 0, "half turn adds no quarter-turn skew")
```

Add a non-optional `expectNear(_:_:_:)` overload beside the existing helper.

- [ ] **Step 2: Run the layout test to verify RED**

```bash
xcrun swiftc \
  "Barrier City/Interaction/KioskScreenLayout.swift" \
  Tests/KioskScreenLayoutTests.swift \
  -o /tmp/kiosk-screen-layout-tests
/tmp/kiosk-screen-layout-tests
```

Expected: compile failure because `faceRotationRadians` does not exist.

- [ ] **Step 3: Implement and consume the orientation contract**

Add `static let faceRotationRadians: Float = .pi` to `KioskScreenLayout`. Change presenter tuning to:

```swift
static let faceRotation = simd_quatf(
    angle: KioskScreenLayout.faceRotationRadians,
    axis: SIMD3<Float>(0, 0, 1))
```

Do not change parent, position, scale, bounds, offset, or fallback orientation.

- [ ] **Step 4: Re-run the test to verify GREEN**

Run Step 2 again. Expected: `KioskScreenLayoutTests: PASS`.

- [ ] **Step 5: Commit the orientation slice**

```bash
git add "Barrier City/Interaction/KioskScreenLayout.swift" \
  "Barrier City/Interaction/KioskScreenPresenter.swift" \
  Tests/KioskScreenLayoutTests.swift
git commit -m "fix: orient kiosk screen content upright"
```

### Task 3: Build the Approved High-Contrast SwiftUI

**Files:**
- Modify: `Barrier City/Interaction/KioskOrderView.swift`

**Interfaces:**
- Consumes: `KioskCategory.allCases` and all Task 1 `InteractionModel` properties/actions.
- Produces: functional 540×960 yellow/black category UI and centered two-action barrier.

- [ ] **Step 1: Define deterministic menu data**

Change `CafeMenuItem` to carry `price: Int` and `categories: Set<KioskCategory>`. Keep a fixed local catalog. Its first other-category item is:

```swift
.init(
    id: "rainbow-smoothie",
    name: "레인보우 스무디",
    price: 6500,
    symbol: "rainbow",
    tint: .pink,
    categories: [.other])
```

Add strawberry, mango, chocolate frappe, cream frappe, mint-choco frappe, yogurt, blueberry, and banana smoothies. Use system symbols and SwiftUI colors; do not copy external product photography.

- [ ] **Step 2: Replace header and categories**

Use a warm yellow background, black home icon, centered `BARRIER CAFE`, and:

```swift
LazyVGrid(
    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
    spacing: 8
) {
    ForEach(KioskCategory.allCases, id: \.self) { category in
        categoryButton(category, interactionModel: im)
    }
}
```

Map the exact Korean titles in a file-local `KioskCategory.title`. Selected tabs are black/white; unselected tabs are yellow with a 2-point black stroke.

- [ ] **Step 3: Connect categories, cards, and summary**

Category buttons call `im.selectKioskCategory(category)` inside a 0.20-second ease-out animation. Cards call `im.selectKioskMenu(id: item.id)`. A selected card gets a 3-point black outline and red `선택` badge. Summary shows selected name, `1개`, and price; otherwise `선택한 상품`, `0개`, `0원`. The black order button remains disabled because payment is out of scope.

- [ ] **Step 4: Build the centered barrier**

Dim the menu with black at 36% opacity. Use the approved title/description. Wire:

```swift
Button("닫기") { _ = im.dismissKioskBarrier() }

Button("직원에게 직접 주문하기") {
    if im.requestKioskStaffHelp() {
        GuideFlowModel.shared.handleQuestEvent(.kioskFailed)
    }
}
```

Preserve the 0.22-second transition, input gating, hover effects, and accessibility labels.

- [ ] **Step 5: Compile and verify the UI**

```bash
xcodebuild -quiet \
  -project "Barrier City.xcodeproj" \
  -scheme "Barrier City" \
  -sdk xrsimulator \
  -destination 'generic/platform=visionOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: exit code 0. Fix only in-scope interface or SwiftUI compile errors.

- [ ] **Step 6: Commit the UI slice**

```bash
git add "Barrier City/Interaction/KioskOrderView.swift"
git commit -m "feat: redesign barrier cafe kiosk menu"
```

### Task 4: Complete Verification and Spatial Handoff

**Files:**
- Verify: all Task 1–3 files

**Interfaces:**
- Consumes: completed state, orientation, and SwiftUI slices.
- Produces: automated evidence and a direct-spatial acceptance checklist.

- [ ] **Step 1: Run all standalone regressions**

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
  "Barrier City/Interaction/KioskScreenLayout.swift" \
  "Barrier City/Interaction/KioskScreenPresenter.swift" \
  "Barrier City/Interaction/SceneTransitionSession.swift" \
  "Barrier City/Interaction/InteractionModel.swift" \
  "Barrier City/Quest/GuideFlowState.swift" \
  Tests/InteractionFlowRegressionTests.swift \
  -o /tmp/interaction-flow-regression-tests
/tmp/interaction-flow-regression-tests
```

Expected: all twelve executables exit 0 and print PASS.

- [ ] **Step 2: Run DialogueKit**

```bash
swift test --package-path Packages/DialogueKit
```

Expected: all 87 tests pass.

- [ ] **Step 3: Run the generic visionOS Simulator build**

Run the Task 3 build command again. Expected: exit code 0.

- [ ] **Step 4: Inspect scope**

```bash
git status --short
git diff --check
git diff --stat HEAD~3..HEAD
```

Expected: only planned kiosk code/tests/docs were committed. The Xcode project file and `docs/design-assets/` remain unstaged.

- [ ] **Step 5: Hand off spatial checks**

Ask the user to confirm: upright screen alignment; normal general-category switching; blocked `기타`; retry after `닫기`; one Mission 3 transition after the primary action; equivalent hand-reach warning; and readable/selectable modal controls from seated eye height. Keep the PR Draft until this direct check is approved.
