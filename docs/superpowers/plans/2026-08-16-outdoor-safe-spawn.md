# Outdoor Safe Spawn Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Spawn the outdoor wheelchair at the farthest floor-supported point on the cafe-door approach line and show the door prompt only after about 0.5 m of approach.

**Architecture:** Keep the spawn geometry in the pure `OutdoorSessionStart` helper and calculate the exit of the door's outward ray from an inset square. Share the 16 m fallback-floor size through `InteractionTuning`, so rendering collision and spawn safety cannot drift apart.

**Tech Stack:** Swift 5, simd, RealityKit, standalone `swiftc` regression executables, visionOS Simulator build

## Global Constraints

- The fallback collision floor remains a 16 m square centered at the world origin.
- The spawn boundary is inset exactly 0.5 m from every floor edge.
- The outdoor start remains on the ray from the cafe center through the cafe door and faces the door.
- The door trigger radius is exactly 1.1 m, requiring approximately 0.5 m of approach from the current safe start.
- The existing guide lock and 0.6 m door-panel offset remain unchanged.
- Do not alter the authored Outdoor asset, wheelchair physics, indoor spawn, kiosk, quest progression, NPC dialogue, or scene transitions.
- Preserve the user's existing unstaged Xcode project-file change.
- Automated verification does not replace direct spatial acceptance on Simulator or Vision Pro.

---

## File Structure

- Modify `Tests/OutdoorSessionStartTests.swift`: cover axis-aligned, diagonal, and fallback safe-boundary behavior.
- Modify `Tests/InteractionFlowRegressionTests.swift`: cover initial prompt suppression and activation after 0.5 m of approach.
- Modify `Barrier City/Interaction/OutdoorSessionStart.swift`: calculate the farthest safe ray point inside the inset ground bounds.
- Modify `Barrier City/Interaction/InteractionModel.swift`: define the shared floor size, safety margin, and 1.1 m trigger radius.
- Modify `Barrier City/Interaction/InteractionSetup.swift`: provide the shared bounds to the pure spawn calculation.
- Modify `Barrier City/ImmersiveView.swift`: construct the collision floor from the shared 16 m tuning value.

### Task 1: Calculate the Farthest Safe Spawn

**Files:**
- Modify: `Tests/OutdoorSessionStartTests.swift`
- Modify: `Barrier City/Interaction/OutdoorSessionStart.swift`

**Interfaces:**
- Consumes: `doorCenter`, `cafeCenter`, `fallbackDoorCenter`, `groundHalfExtent`, and `safetyMargin`, all in world-space meters.
- Produces: `OutdoorSessionStart.positionOutsideCafe(doorCenter:cafeCenter:fallbackDoorCenter:groundHalfExtent:safetyMargin:) -> SIMD2<Float>`.

- [ ] **Step 1: Write failing boundary regressions**

Replace the distance-based assertions with literal safe-boundary expectations:

```swift
let outside = OutdoorSessionStart.positionOutsideCafe(
    doorCenter: SIMD2<Float>(0, -6),
    cafeCenter: .zero,
    fallbackDoorCenter: SIMD2<Float>(0, -6),
    groundHalfExtent: 8,
    safetyMargin: 0.5)
expectNear(outside.x, 0, "safe spawn preserves centered door X")
expectNear(outside.y, -7.5, "safe spawn stops inside the negative-Z floor edge")

let diagonalOutside = OutdoorSessionStart.positionOutsideCafe(
    doorCenter: SIMD2<Float>(3, 4),
    cafeCenter: .zero,
    fallbackDoorCenter: SIMD2<Float>(0, -6),
    groundHalfExtent: 8,
    safetyMargin: 0.5)
expectNear(diagonalOutside.x, 5.625, "diagonal spawn follows the door ray on X")
expectNear(diagonalOutside.y, 7.5, "diagonal spawn reaches the inset floor edge on Z")

let fallbackOutside = OutdoorSessionStart.positionOutsideCafe(
    doorCenter: .zero,
    cafeCenter: .zero,
    fallbackDoorCenter: SIMD2<Float>(0, -6),
    groundHalfExtent: 8,
    safetyMargin: 0.5)
expectNear(fallbackOutside.y, -7.5, "coincident cafe and door use the fallback ray")
```

- [ ] **Step 2: Run the focused test to verify RED**

Run:

```bash
xcrun swiftc "Barrier City/Interaction/OutdoorSessionStart.swift" Tests/OutdoorSessionStartTests.swift -o /tmp/outdoor-session-start-tests
/tmp/outdoor-session-start-tests
```

Expected: compiler failures for the missing `groundHalfExtent` and `safetyMargin` arguments.

- [ ] **Step 3: Implement the minimal inset-ray calculation**

Change `positionOutsideCafe` to accept the new bounds inputs. Normalize the existing outward fallback direction, compute `safeExtent = max(0, groundHalfExtent - max(0, safetyMargin))`, and calculate the positive ray-exit distance for X and Z. Return `doorCenter + outward * exitDistance`; if no forward intersection exists, return `simd_clamp(doorCenter, lowerBound, upperBound)`.

- [ ] **Step 4: Run the focused test to verify GREEN**

Re-run Step 2 and expect exit code 0.

- [ ] **Step 5: Commit the safe-spawn calculation**

```bash
git add "Barrier City/Interaction/OutdoorSessionStart.swift" Tests/OutdoorSessionStartTests.swift
git commit -m "fix: clamp outdoor spawn to supported ground"
```

### Task 2: Share Floor Bounds and Preserve Delayed Prompt Behavior

**Files:**
- Modify: `Tests/InteractionFlowRegressionTests.swift`
- Modify: `Barrier City/Interaction/InteractionModel.swift`
- Modify: `Barrier City/Interaction/InteractionSetup.swift`
- Modify: `Barrier City/ImmersiveView.swift`

**Interfaces:**
- Consumes: the safe-spawn API from Task 1.
- Produces: `InteractionTuning.outdoorGroundPlaneSize == 16`, `InteractionTuning.outdoorSpawnSafetyMargin == 0.5`, and `InteractionTuning.doorTriggerRadius == 1.1` as shared runtime tuning.

- [ ] **Step 1: Write the failing interaction regression**

Call the new spawn API with `InteractionTuning.outdoorGroundPlaneSize / 2` and `InteractionTuning.outdoorSpawnSafetyMargin`. Assert the literal start Z is `-7.5`, the prompt is hidden initially, and a 0.5 m positive-Z approach activates the door trigger.

- [ ] **Step 2: Run the interaction regression to verify RED**

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

Expected: compiler failures because the shared floor and margin tuning values do not exist.

- [ ] **Step 3: Add shared tuning and connect both consumers**

Add these values to `InteractionTuning`:

```swift
static let outdoorGroundPlaneSize: Float = 16
static let outdoorSpawnSafetyMargin: Float = 0.5
static let doorTriggerRadius: Float = 1.1
```

Pass half the plane size and the safety margin from `InteractionSetup` into `positionOutsideCafe`. In `ImmersiveView`, replace both horizontal `16` literals in `ShapeResource.generateBox` with `InteractionTuning.outdoorGroundPlaneSize`.

- [ ] **Step 4: Run the interaction regression to verify GREEN**

Re-run Step 2 and expect exit code 0.

- [ ] **Step 5: Run complete verification**

Run every standalone executable under `Tests`, `swift test --package-path Packages/DialogueKit`, and:

```bash
xcodebuild -project "Barrier City.xcodeproj" -scheme "Barrier City" -sdk xrsimulator -destination 'generic/platform=visionOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: all regressions and 87 DialogueKit tests pass; the visionOS Simulator build exits 0. Directly verify later that the chair does not fall and the prompt appears after the intended approach.

- [ ] **Step 6: Commit the integration slice**

```bash
git add "Barrier City/ImmersiveView.swift" "Barrier City/Interaction/InteractionModel.swift" "Barrier City/Interaction/InteractionSetup.swift" Tests/InteractionFlowRegressionTests.swift
git commit -m "fix: align outdoor spawn with collision floor"
```
