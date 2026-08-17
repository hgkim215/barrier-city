# Kiosk Screen UI Merge Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the malformed conflict resolution in `d6d7cd3` while preserving both the latest `develop` scene-transition lifecycle and the kiosk Screen UI behavior.

**Architecture:** Keep `InteractionModel` as the kiosk state facade and keep `SceneSwitcher.switchToIndoor()` as the only mutating indoor transition boundary. `resolveIndoorLayout()` remains a pure layout calculator, while Screen attachment placement happens during the atomic transition commit.

**Tech Stack:** Swift 5, Observation, RealityKit, SwiftUI, visionOS Simulator, standalone `swiftc` regression executables

## Global Constraints

- Work only in the main checkout on `codex/kiosk-screen-ui`.
- Preserve the existing unstaged `Barrier City.xcodeproj/project.pbxproj` change.
- Keep PR #10 in Draft state.
- Do not restore the obsolete `kioskTooHighShown` state.

---

### Task 1: Repair InteractionModel conflict resolution

**Files:**
- Modify: `Barrier City/Interaction/InteractionModel.swift:178-204`
- Test: `Tests/InteractionFlowRegressionTests.swift`

**Interfaces:**
- Consumes: `KioskInteractionState.requestStaffHelp() -> Bool`, `dismissActive()`, and `resetKioskSession()`.
- Produces: `requestKioskStaffHelp() -> Bool` and `tearDown()` as independent class methods.

- [ ] **Step 1: Verify RED**

Run `xcrun swiftc -parse "Barrier City/Interaction/InteractionModel.swift"` and confirm the missing class brace and local `private`/`static` method errors.

- [ ] **Step 2: Restore the intended method boundaries**

Complete `requestKioskStaffHelp()` with `dismissActive()`, `resetKioskReachDetectors()`, and `return true`. Keep `tearDown()` separate, remove `kioskTooHighShown`, and remove obsolete `acknowledgeKioskBarrier()`.

- [ ] **Step 3: Verify GREEN for the interaction flow**

Compile and run:

```bash
xcrun swiftc \
  "Barrier City/Interaction/KioskInteractionState.swift" \
  "Barrier City/Interaction/KioskReachAttemptDetector.swift" \
  "Barrier City/Interaction/SceneTransitionSession.swift" \
  "Barrier City/Interaction/InteractionModel.swift" \
  "Barrier City/Quest/GuideFlowState.swift" \
  Tests/InteractionFlowRegressionTests.swift \
  -o /tmp/interaction-flow-regression-tests
/tmp/interaction-flow-regression-tests
```

Expected: `InteractionFlowRegressionTests: PASS`.

### Task 2: Repair SceneSwitcher conflict resolution

**Files:**
- Modify: `Barrier City/Interaction/SceneSwitcher.swift:98-121`
- Modify: `Barrier City/Interaction/SceneSwitcher.swift:146-215`
- Test: full visionOS Simulator build

**Interfaces:**
- Consumes: `KioskScreenPresenter.install(attachment:in:worldRoot:)`, `InteractionModel.updateKioskContext(...)`, and `InteractionModel.applyKioskScreenPlacement(_:)`.
- Produces: a single atomic indoor transition and a pure `resolveIndoorLayout(...) -> IndoorLayout`.

- [ ] **Step 1: Move kiosk integration into the atomic transition commit**

After assigning the indoor trigger, initialize kiosk context and install the `kioskScreen` attachment on `prepared.visible`; retain billboard fallback when no attachment exists.

- [ ] **Step 2: Remove the duplicated transition body from resolveIndoorLayout**

After computing `spawn` and `heading`, return `IndoorLayout(kioskCenter:spawn:heading:)` immediately.

- [ ] **Step 3: Run focused and full verification**

Run the kiosk pure-state/layout/reach tests, established interaction regressions, `swift test --package-path Packages/DialogueKit`, and:

```bash
xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/barrier-city-kiosk-merge-repair \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: all tests pass and `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit and update the Draft PR branch**

Stage only both repair source files and these two documentation files, commit with a narrow Korean message, then push `codex/kiosk-screen-ui`. Confirm PR #10 remains Draft.
