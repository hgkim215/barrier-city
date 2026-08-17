# Outdoor Map Loading Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load the current `Outdoor` RealityKit scene on immersive entry and make visible/collision scene load failures diagnosable.

**Architecture:** Add a RealityKit-independent `ImmersiveSceneCatalog` as the single source of the outdoor scene name. `ImmersiveView` consumes that catalog in both entity load paths and reports each failure through `Logger` while preserving the existing partial-scene fallback behavior.

**Tech Stack:** Swift 5, SwiftUI, RealityKit, OSLog, standalone `swiftc` regression executable, visionOS Simulator

## Global Constraints

- Work only in the main checkout on `codex/kiosk-screen-ui`.
- Preserve the existing unstaged `Barrier City.xcodeproj/project.pbxproj` change.
- Keep PR #10 in Draft state.
- Do not change outdoor coordinates, lighting, collision generation, Indoor transition, or kiosk behavior.
- Do not restore `Map.usda` and do not accept `Map` as a fallback asset name.

---

### Task 1: Add the verified immersive scene catalog

**Files:**
- Create: `Barrier City/ImmersiveSceneCatalog.swift`
- Create: `Tests/ImmersiveSceneCatalogTests.swift`

**Interfaces:**
- Consumes: the RealityKit asset directory path passed as `CommandLine.arguments[1]`.
- Produces: `ImmersiveSceneCatalog.outdoor: String` with value `"Outdoor"`.

- [ ] **Step 1: Write the failing catalog test**

```swift
import Foundation

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

@main
struct ImmersiveSceneCatalogTests {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fail("expected RealityKit asset directory path")
        }
        let assetDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let outdoorAsset = assetDirectory
            .appendingPathComponent(ImmersiveSceneCatalog.outdoor)
            .appendingPathExtension("usda")
        guard FileManager.default.fileExists(atPath: outdoorAsset.path) else {
            fail("configured outdoor scene has no USDA asset: \(outdoorAsset.path)")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify RED**

Run:

```bash
xcrun swiftc 'Barrier City/ImmersiveSceneCatalog.swift' Tests/ImmersiveSceneCatalogTests.swift -o /tmp/immersive-scene-catalog-tests
```

Expected: compilation fails because `Barrier City/ImmersiveSceneCatalog.swift` does not exist.

- [ ] **Step 3: Add the minimal catalog**

```swift
enum ImmersiveSceneCatalog {
    static let outdoor = "Outdoor"
}
```

- [ ] **Step 4: Run the catalog test to verify GREEN**

Run:

```bash
xcrun swiftc 'Barrier City/ImmersiveSceneCatalog.swift' Tests/ImmersiveSceneCatalogTests.swift -o /tmp/immersive-scene-catalog-tests
/tmp/immersive-scene-catalog-tests 'Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets'
```

Expected: both commands exit 0.

### Task 2: Connect both map load paths and expose failures

**Files:**
- Modify: `Barrier City/ImmersiveView.swift:1-78`
- Test: `Tests/ImmersiveSceneCatalogTests.swift`

**Interfaces:**
- Consumes: `ImmersiveSceneCatalog.outdoor` and `realityKitContentBundle`.
- Produces: one visible `Outdoor` entity and one collision-only `Outdoor` entity; reports each failed load in the `ImmersiveScene` log category.

- [ ] **Step 1: Add OSLog and a scoped logger**

Add `import OSLog` and this property to `ImmersiveView`:

```swift
private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BarrierCity",
    category: "ImmersiveScene")
```

- [ ] **Step 2: Replace the visible map's silent optional load**

Use `do/catch`, load `Entity(named: ImmersiveSceneCatalog.outdoor, in: realityKitContentBundle)`, preserve the existing child setup, and log `error.localizedDescription` with public privacy on failure.

- [ ] **Step 3: Replace the collision map's silent optional load**

Use the same catalog entry and separate `do/catch`; preserve collision generation and render stripping, and identify the collision path in its failure log.

- [ ] **Step 4: Verify the focused test and Swift syntax**

Run:

```bash
xcrun swiftc 'Barrier City/ImmersiveSceneCatalog.swift' Tests/ImmersiveSceneCatalogTests.swift -o /tmp/immersive-scene-catalog-tests
/tmp/immersive-scene-catalog-tests 'Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets'
xcrun swiftc -parse 'Barrier City/ImmersiveView.swift' 'Barrier City/ImmersiveSceneCatalog.swift'
```

Expected: all commands exit 0.

### Task 3: Run regressions and the visionOS Simulator build

**Files:**
- Verify: `Barrier City/ImmersiveSceneCatalog.swift`
- Verify: `Barrier City/ImmersiveView.swift`
- Verify: `Tests/ImmersiveSceneCatalogTests.swift`

**Interfaces:**
- Consumes: the completed implementation from Tasks 1 and 2.
- Produces: fresh test and build evidence for the Draft PR branch.

- [ ] **Step 1: Run the existing outdoor session test**

```bash
xcrun swiftc 'Barrier City/Interaction/OutdoorSessionStart.swift' Tests/OutdoorSessionStartTests.swift -o /tmp/outdoor-session-start-tests
/tmp/outdoor-session-start-tests
```

- [ ] **Step 2: Run DialogueKit tests**

```bash
swift test --package-path Packages/DialogueKit
```

- [ ] **Step 3: Build the full app for visionOS Simulator**

```bash
xcodebuild -project 'Barrier City.xcodeproj' -scheme 'Barrier City' -destination 'generic/platform=visionOS Simulator' -derivedDataPath /tmp/barrier-city-outdoor-map-repair CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Review and commit only scoped files**

Run `git diff --check`, inspect `git diff --stat` and `git status --short`, then stage only the catalog, its test, `ImmersiveView`, and the amended design/plan documents. Commit with `fix: 야외 맵 로딩 복구` and leave the PR in Draft.
