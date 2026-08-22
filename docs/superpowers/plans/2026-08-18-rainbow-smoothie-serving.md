# Rainbow Smoothie Serving Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After the clerk finishes confirming one Rainbow Smoothie order, wait exactly 10 seconds, reveal one preloaded smoothie on the empty `BarTable` counter area, announce pickup once, and make every later NPC conversation aware of whether the drink is preparing or ready.

**Architecture:** `CafeOrderSession` is the app-owned source of truth, `RainbowSmoothieServingController` owns the cancellable delay, and `RainbowSmoothiePresenter` owns the single RealityKit entity and its counter anchor. `NPCDialogueController` receives a read-only fulfillment context for both legacy and Realtime prompts, while `NPCClerkController` only routes the existing post-TTS `.orderPlaced` event and gives the ready-announcement queue opportunities to drain.

**Tech Stack:** Swift 5, Swift Concurrency, SwiftUI Observation, RealityKit, RealityKitContent, DialogueKit, XCTest, standalone `swiftc` contract executables, visionOS Simulator, Vision Pro

## Global Constraints

- Work only in `/Users/hyeongikim/Documents/2_Projects/barrier-city` on branch `codex/rainbow-smoothie-serving`; do not create or use a linked worktree.
- Preserve all unrelated user/Xcode changes and never stage `Barrier City.xcodeproj/project.pbxproj`, Reality Composer Pro `PluginData`, `SceneMetadataList.json`, `hyeongikim.rcuserdata`, or unrelated `docs/design-assets/` files.
- Start the 10-second delay only when the existing `.orderPlaced` event is published after the order-confirmation audio fully finishes.
- Accept exactly one Rainbow Smoothie order per Indoor session; duplicate order events must not restart the delay, create another entity, or repeat the ready announcement.
- Use the exact automatic ready line: `주문하신 레인보우 스무디 나왔습니다. 카운터에서 가져가 주세요.`
- Place only `RainbowSmoothie.usdz`; do not create a tray, tray placeholder, pickup interaction, wheelchair carry flow, seat placement flow, additional menu items, quantities above one, or a new quest stage.
- Never place an asset at a guessed world-origin fallback when `RainbowSmoothie.usdz` or `BarTable` is unavailable; transition the order session to `failed` and suppress ready state/audio.
- Keep the smoothie as one reusable RealityKit entity owned by `RainbowSmoothiePresenter`, so a later feature can reparent that same entity to a wheelchair anchor.
- Do not report immersive completion from tests or build alone; directly verify timing, placement, state-aware dialogue, duplicate protection, and reset in Simulator, then repeat spatial/audio acceptance on Vision Pro when hardware is available.

---

## File Structure

### Create

- `Packages/DialogueKit/Sources/DialogueKit/RainbowSmoothieFulfillmentContext.swift` — immutable app-to-dialogue fulfillment facts and prompt wording; it does not own app state.
- `Barrier City/Interaction/CafeOrderSession.swift` — RealityKit-independent phase and session-generation state machine.
- `Barrier City/Interaction/RainbowSmoothieServingController.swift` — one-order delay orchestration with injected sleeper and presenter protocol.
- `Barrier City/Interaction/RainbowSmoothiePlacement.swift` — pure counter-position and scale calculations shared by the presenter and standalone tests.
- `Barrier City/Interaction/RainbowSmoothiePresenter.swift` — owns the single smoothie entity, `BarTableServingAnchor`, visibility, and teardown.
- `Barrier City/Dialogue/CafeOrderDialogueContext.swift` — maps app-owned `CafeOrderPhase` to DialogueKit's immutable context.
- `Barrier City/Dialogue/OrderReadyAnnouncementGate.swift` — pure exactly-once immediate/queued announcement decision state.
- `Tests/CafeOrderSessionTests.swift` — standalone phase and stale-generation regression executable.
- `Tests/RainbowSmoothieServingControllerTests.swift` — standalone delay, duplicate, failure, and cancellation regression executable.
- `Tests/RainbowSmoothiePlacementTests.swift` — standalone counter coordinate and scale regression executable.
- `Tests/OrderReadyAnnouncementGateTests.swift` — standalone exactly-once queue regression executable.

### Modify

- `Packages/DialogueKit/Sources/DialogueKit/PromptBuilder.swift` — inject fulfillment facts into legacy prompts.
- `Packages/DialogueKit/Sources/DialogueKit/RealtimeConversationGuide.swift` — inject the same facts into Realtime instructions.
- `Packages/DialogueKit/Sources/DialogueKit/DialogueOrchestrator.swift` — prevent order progress and `.orderPlaced` when the app says ordering is locked.
- `Packages/DialogueKit/Tests/DialogueKitTests/PromptBuilderTests.swift` — verify preparing/ready/failed prompt facts in both dialogue modes.
- `Packages/DialogueKit/Tests/DialogueKitTests/DialogueOrchestratorTests.swift` — verify an already-ordered session cannot emit another `.orderPlaced`.
- `Barrier City/ImmersiveSceneCatalog.swift` — centralize `Indoor`, `RainbowSmoothie`, and `BarTable` names.
- `Tests/ImmersiveSceneCatalogTests.swift` — verify the USDZ exists and the Indoor asset preserves the named counter contract.
- `Barrier City/Dialogue/NPCDialogueController.swift` — read the current session, pass its context into both dialogue paths, and deliver the deterministic ready TTS/subtitle once.
- `Barrier City/NPC/NPCClerkController.swift` — route `.orderPlaced`, drain queued ready speech, and block new greetings while that speech owns the voice channel.
- `Barrier City/AppModel.swift` — construct and retain the session/presenter/serving/dialogue/clerk dependency graph.
- `Barrier City/Interaction/SceneSwitcher.swift` — preload the smoothie with Indoor, install it hidden under `BarTable`, and start the Indoor order generation.
- `Barrier City/ImmersiveView.swift` — reset serving before resetting the clerk/dialogue when the immersive session closes.

The app target uses a file-system-synchronized group, so new Swift files under `Barrier City/` are discovered automatically. Do not edit `project.pbxproj` for file membership.

---

### Task 1: Make fulfillment state an explicit DialogueKit input

**Files:**
- Create: `Packages/DialogueKit/Sources/DialogueKit/RainbowSmoothieFulfillmentContext.swift`
- Modify: `Packages/DialogueKit/Sources/DialogueKit/PromptBuilder.swift:8-45`
- Modify: `Packages/DialogueKit/Sources/DialogueKit/RealtimeConversationGuide.swift:27-143`
- Modify: `Packages/DialogueKit/Sources/DialogueKit/DialogueOrchestrator.swift:59-116`
- Test: `Packages/DialogueKit/Tests/DialogueKitTests/PromptBuilderTests.swift`
- Test: `Packages/DialogueKit/Tests/DialogueKitTests/DialogueOrchestratorTests.swift`

**Interfaces:**
- Consumes: existing `OrderServiceDecision`, `RainbowSmoothieOrderDecision`, and app-provided fulfillment facts.
- Produces: `RainbowSmoothieFulfillmentContext`, `PromptBuilder.build(...fulfillmentContext:)`, `RealtimeConversationGuide.instructions(...fulfillmentContext:)`, and `DialogueOrchestrator.handle(...fulfillmentContext:onSentence:)`.

- [ ] **Step 1: Add failing prompt and duplicate-event tests**

Add these tests to `PromptBuilderTests`:

```swift
func test_fulfillmentContext_isIdenticalInLegacyAndRealtimeGuidance() {
    for (context, requiredFact) in [
        (RainbowSmoothieFulfillmentContext.preparing, "FULFILLMENT=preparing"),
        (.readyAtCounter, "FULFILLMENT=readyAtCounter"),
        (.failed, "FULFILLMENT=failed"),
    ] {
        let legacy = PromptBuilder().build(
            persona: persona,
            climate: SocialClimate(),
            history: [],
            userUtterance: "제 스무디 어떻게 됐어요?",
            turnLimit: 8,
            fulfillmentContext: context
        ).first!.content
        let realtime = RealtimeConversationGuide().instructions(
            persona: persona,
            climate: SocialClimate(),
            fulfillmentContext: context
        )

        XCTAssertTrue(legacy.contains(requiredFact))
        XCTAssertTrue(realtime.contains(requiredFact))
        XCTAssertTrue(legacy.contains(context.promptGuide))
        XCTAssertTrue(realtime.contains(context.promptGuide))
    }
}

func test_orderedContexts_forbidASecondOrderCompletion() {
    for context in [
        RainbowSmoothieFulfillmentContext.preparing,
        .readyAtCounter,
        .failed,
    ] {
        XCTAssertFalse(context.allowsOrderCompletion)
    }
}
```

Add this test to `DialogueOrchestratorTests` using the file's existing `makeSUT` helper:

```swift
func test_preparingFulfillment_cannotPublishAnotherOrderPlacedEvent() async {
    let sut = makeSUT(MockLLM([.token("이미 주문 상태를 확인해 드릴게요."), .done]))

    let result = await sut.handle(
        utterance: "레인보우 스무디 한 잔 더 주문할게요",
        history: [],
        fulfillmentContext: .preparing
    )

    XCTAssertNil(result.event)
    XCTAssertFalse(result.usedFallback)
}
```

- [ ] **Step 2: Run DialogueKit tests to verify RED**

Run:

```bash
swift test --package-path Packages/DialogueKit --filter 'PromptBuilderTests|DialogueOrchestratorTests'
```

Expected: compilation fails because `RainbowSmoothieFulfillmentContext` and the new parameters do not exist.

- [ ] **Step 3: Add the immutable fulfillment context**

Create `RainbowSmoothieFulfillmentContext.swift`:

```swift
public enum RainbowSmoothieFulfillmentContext: String, Equatable, Sendable {
    case orderingAllowed
    case preparing
    case readyAtCounter
    case failed

    public var allowsOrderCompletion: Bool { self == .orderingAllowed }

    public var promptGuide: String {
        switch self {
        case .orderingAllowed:
            return "FULFILLMENT=orderingAllowed. No Rainbow Smoothie order has been placed yet. Follow the normal order-collection flow."
        case .preparing:
            return "FULFILLMENT=preparing. Exactly one Rainbow Smoothie is already ordered and still being prepared. Acknowledge that fact, ask the visitor to wait briefly, and never place or claim another order."
        case .readyAtCounter:
            return "FULFILLMENT=readyAtCounter. The visitor's one Rainbow Smoothie is ready at the counter. Direct them to collect that existing drink and never place another order."
        case .failed:
            return "FULFILLMENT=failed. The existing Rainbow Smoothie service cannot be completed right now. State that it is currently unavailable; never claim an order was placed or that a drink is ready."
        }
    }
}
```

- [ ] **Step 4: Thread the context through both prompt builders**

Extend `PromptBuilder.build` with this defaulted final parameter:

```swift
fulfillmentContext: RainbowSmoothieFulfillmentContext = .orderingAllowed
```

Insert these exact lines in the existing `system` multiline string immediately after the current `# App-owned order state for this turn` decision guide:

```swift
# App-owned fulfillment state
\(fulfillmentContext.promptGuide)
```

Extend `RealtimeConversationGuide.instructions` with this defaulted final parameter:

```swift
fulfillmentContext: RainbowSmoothieFulfillmentContext = .orderingAllowed
```

Insert these exact lines immediately before the existing `# Required conversation flow` heading:

```swift
# App-owned fulfillment state
\(fulfillmentContext.promptGuide)
```

- [ ] **Step 5: Lock order progress when the app has already accepted an order**

Add `fulfillmentContext: RainbowSmoothieFulfillmentContext = .orderingAllowed` between the existing `history` and `onSentence` parameters of `DialogueOrchestrator.handle`. Replace the block from `let acceptedBeforeTurn` through `let resolvedMissionEvent` with:

```swift
let acceptedBeforeTurn = orderProgress.acceptsCounterOrder
let orderCollectionDecision: RainbowSmoothieOrderDecision
if fulfillmentContext.allowsOrderCompletion {
    orderCollectionDecision = orderProgress.observe(userTranscript: utterance)
} else {
    orderCollectionDecision = .continueConversation
}
let orderDecision = fulfillmentContext.allowsOrderCompletion
    ? orderServiceDecision(
        for: intent,
        utterance: utterance,
        acceptedBeforeTurn: acceptedBeforeTurn)
    : .notApplicable
let resolvedMissionEvent = fulfillmentContext.allowsOrderCompletion
    ? missionEvent(
        for: intent,
        orderCollectionDecision: orderCollectionDecision)
    : nil
```

Add the final labeled argument to the existing `promptBuilder.build` call:

```swift
fulfillmentContext: fulfillmentContext
```

- [ ] **Step 6: Run the focused tests to verify GREEN**

Run:

```bash
swift test --package-path Packages/DialogueKit --filter 'PromptBuilderTests|DialogueOrchestratorTests'
```

Expected: selected tests pass, including the new prompt and duplicate-event cases.

- [ ] **Step 7: Commit the DialogueKit contract**

```bash
git add Packages/DialogueKit/Sources/DialogueKit/RainbowSmoothieFulfillmentContext.swift \
  Packages/DialogueKit/Sources/DialogueKit/PromptBuilder.swift \
  Packages/DialogueKit/Sources/DialogueKit/RealtimeConversationGuide.swift \
  Packages/DialogueKit/Sources/DialogueKit/DialogueOrchestrator.swift \
  Packages/DialogueKit/Tests/DialogueKitTests/PromptBuilderTests.swift \
  Packages/DialogueKit/Tests/DialogueKitTests/DialogueOrchestratorTests.swift
git commit -m "feat: make dialogue aware of smoothie fulfillment"
```

---

### Task 2: Build the order session and cancellable serving state machine

**Files:**
- Create: `Barrier City/Interaction/CafeOrderSession.swift`
- Create: `Barrier City/Interaction/RainbowSmoothieServingController.swift`
- Create: `Tests/CafeOrderSessionTests.swift`
- Create: `Tests/RainbowSmoothieServingControllerTests.swift`

**Interfaces:**
- Consumes: an injected `RainbowSmoothiePresenting`, delay `Duration`, sleeper closure, and ready callback.
- Produces: `CafeOrderPhase`, `CafeOrderSession`, `RainbowSmoothiePresenting`, and `RainbowSmoothieServingController` with `enterIndoor()`, `acceptOrder()`, and `resetForOutdoor()`.

- [ ] **Step 1: Write the failing session-state executable**

Create `Tests/CafeOrderSessionTests.swift`:

```swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

@main
@MainActor
struct CafeOrderSessionTests {
    static func main() {
        let session = CafeOrderSession()
        let firstGeneration = session.beginIndoorSession()
        expect(session.phase == .notOrdered, "Indoor entry starts without an order")
        expect(session.acceptOrder() == firstGeneration, "first order is accepted")
        expect(session.phase == .preparing, "accepted order starts preparation")
        expect(session.acceptOrder() == nil, "duplicate order is rejected")
        expect(session.markReady(generation: firstGeneration), "current preparation becomes ready")
        expect(session.phase == .readyAtCounter, "ready phase is stored")

        let secondGeneration = session.beginIndoorSession()
        expect(secondGeneration != firstGeneration, "new Indoor session advances generation")
        expect(!session.markReady(generation: firstGeneration), "stale generation cannot become ready")
        expect(session.phase == .notOrdered, "stale completion does not mutate new session")
        expect(session.markFailed(generation: secondGeneration), "current session records asset failure")
        expect(session.phase == .failed, "failed phase is stored")
        expect(session.acceptOrder() == nil, "failed service rejects order completion")

        session.resetForOutdoor()
        expect(session.phase == .notOrdered, "Outdoor reset returns to initial phase")
        print("PASS: CafeOrderSessionTests")
    }
}
```

- [ ] **Step 2: Run the session test to verify RED**

Run:

```bash
xcrun swiftc 'Barrier City/Interaction/CafeOrderSession.swift' Tests/CafeOrderSessionTests.swift -o /tmp/cafe-order-session-tests
```

Expected: compilation fails because `CafeOrderSession.swift` does not exist.

- [ ] **Step 3: Implement the minimal session state machine**

Create `CafeOrderSession.swift`:

```swift
import Foundation

enum CafeOrderPhase: String, Equatable, Sendable {
    case notOrdered
    case preparing
    case readyAtCounter
    case failed
}

@MainActor
final class CafeOrderSession {
    private(set) var phase: CafeOrderPhase = .notOrdered
    private(set) var generation = 0

    @discardableResult
    func beginIndoorSession() -> Int {
        generation &+= 1
        phase = .notOrdered
        return generation
    }

    func acceptOrder() -> Int? {
        guard phase == .notOrdered else { return nil }
        phase = .preparing
        return generation
    }

    @discardableResult
    func markReady(generation: Int) -> Bool {
        guard generation == self.generation, phase == .preparing else { return false }
        phase = .readyAtCounter
        return true
    }

    @discardableResult
    func markFailed(generation: Int) -> Bool {
        guard generation == self.generation,
              phase == .notOrdered || phase == .preparing else { return false }
        phase = .failed
        return true
    }

    func resetForOutdoor() {
        generation &+= 1
        phase = .notOrdered
    }
}
```

- [ ] **Step 4: Verify the session state test is GREEN**

Run:

```bash
xcrun swiftc 'Barrier City/Interaction/CafeOrderSession.swift' Tests/CafeOrderSessionTests.swift -o /tmp/cafe-order-session-tests
/tmp/cafe-order-session-tests
```

Expected: prints `PASS: CafeOrderSessionTests`.

- [ ] **Step 5: Write the failing serving-controller executable**

Create `Tests/RainbowSmoothieServingControllerTests.swift` with an immediate sleeper and fake presenter:

```swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

@MainActor
private final class PresenterSpy: RainbowSmoothiePresenting {
    var isInstalled = true
    var revealResult = true
    var revealCount = 0
    var resetCount = 0

    func revealAtCounter() -> Bool {
        revealCount += 1
        return revealResult
    }

    func reset() {
        resetCount += 1
        isInstalled = false
    }
}

private actor DelayRecorder {
    private(set) var received: Duration?

    func sleep(for duration: Duration) {
        received = duration
    }
}

private actor ControlledSleeper {
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@main
@MainActor
struct RainbowSmoothieServingControllerTests {
    static func main() async {
        let session = CafeOrderSession()
        let presenter = PresenterSpy()
        let delayRecorder = DelayRecorder()
        var readyCount = 0
        let controller = RainbowSmoothieServingController(
            session: session,
            presenter: presenter,
            preparationDelay: .seconds(10),
            sleep: { await delayRecorder.sleep(for: $0) },
            onReady: { readyCount += 1 })

        controller.enterIndoor()
        controller.acceptOrder()
        controller.acceptOrder()
        await Task.yield()
        await Task.yield()
        let recordedDelay = await delayRecorder.received
        expect(recordedDelay == .seconds(10), "controller requests ten seconds")
        expect(session.phase == .readyAtCounter, "successful delay becomes ready")
        expect(presenter.revealCount == 1, "duplicate order reveals one entity")
        expect(readyCount == 1, "ready callback fires once")

        presenter.isInstalled = true
        presenter.revealResult = false
        controller.enterIndoor()
        controller.acceptOrder()
        await Task.yield()
        await Task.yield()
        expect(session.phase == .failed, "presenter failure is explicit")
        expect(readyCount == 1, "failed reveal has no ready callback")

        presenter.isInstalled = false
        controller.enterIndoor()
        expect(session.phase == .failed, "missing installation fails before ordering")

        controller.resetForOutdoor()
        expect(session.phase == .notOrdered, "reset restores order state")
        expect(presenter.resetCount == 1, "reset tears down presenter")

        let cancellationSession = CafeOrderSession()
        let cancellationPresenter = PresenterSpy()
        let controlledSleeper = ControlledSleeper()
        var cancelledReadyCount = 0
        let cancellable = RainbowSmoothieServingController(
            session: cancellationSession,
            presenter: cancellationPresenter,
            sleep: { _ in await controlledSleeper.sleep() },
            onReady: { cancelledReadyCount += 1 })
        cancellable.enterIndoor()
        cancellable.acceptOrder()
        await Task.yield()
        cancellable.resetForOutdoor()
        await controlledSleeper.finish()
        await Task.yield()
        expect(cancellationPresenter.revealCount == 0, "cancelled delay cannot reveal")
        expect(cancelledReadyCount == 0, "cancelled delay cannot announce")
        expect(cancellationSession.phase == .notOrdered, "cancelled delay cannot mutate reset session")
        print("PASS: RainbowSmoothieServingControllerTests")
    }
}
```

- [ ] **Step 6: Run the controller test to verify RED**

Run:

```bash
xcrun swiftc 'Barrier City/Interaction/CafeOrderSession.swift' \
  'Barrier City/Interaction/RainbowSmoothieServingController.swift' \
  Tests/RainbowSmoothieServingControllerTests.swift \
  -o /tmp/rainbow-smoothie-serving-controller-tests
```

Expected: compilation fails because the presenter protocol and controller do not exist.

- [ ] **Step 7: Implement the serving controller**

Create `RainbowSmoothieServingController.swift`:

```swift
import Foundation

@MainActor
protocol RainbowSmoothiePresenting: AnyObject {
    var isInstalled: Bool { get }
    func revealAtCounter() -> Bool
    func reset()
}

@MainActor
final class RainbowSmoothieServingController {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    typealias ReadyHandler = @MainActor @Sendable () -> Void

    private let session: CafeOrderSession
    private let presenter: any RainbowSmoothiePresenting
    private let preparationDelay: Duration
    private let sleep: Sleeper
    private let onReady: ReadyHandler
    private var preparationTask: Task<Void, Never>?

    init(
        session: CafeOrderSession,
        presenter: any RainbowSmoothiePresenting,
        preparationDelay: Duration = .seconds(10),
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        onReady: @escaping ReadyHandler
    ) {
        self.session = session
        self.presenter = presenter
        self.preparationDelay = preparationDelay
        self.sleep = sleep
        self.onReady = onReady
    }

    func enterIndoor() {
        preparationTask?.cancel()
        preparationTask = nil
        let generation = session.beginIndoorSession()
        if !presenter.isInstalled {
            session.markFailed(generation: generation)
        }
    }

    func acceptOrder() {
        guard presenter.isInstalled,
              let generation = session.acceptOrder() else { return }
        preparationTask?.cancel()
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(self.preparationDelay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  generation == self.session.generation else { return }
            guard self.presenter.revealAtCounter() else {
                self.session.markFailed(generation: generation)
                self.preparationTask = nil
                return
            }
            guard self.session.markReady(generation: generation) else { return }
            self.preparationTask = nil
            self.onReady()
        }
    }

    func resetForOutdoor() {
        preparationTask?.cancel()
        preparationTask = nil
        presenter.reset()
        session.resetForOutdoor()
    }
}
```

- [ ] **Step 8: Verify both standalone state tests are GREEN**

Run:

```bash
xcrun swiftc 'Barrier City/Interaction/CafeOrderSession.swift' Tests/CafeOrderSessionTests.swift -o /tmp/cafe-order-session-tests
/tmp/cafe-order-session-tests
xcrun swiftc 'Barrier City/Interaction/CafeOrderSession.swift' \
  'Barrier City/Interaction/RainbowSmoothieServingController.swift' \
  Tests/RainbowSmoothieServingControllerTests.swift \
  -o /tmp/rainbow-smoothie-serving-controller-tests
/tmp/rainbow-smoothie-serving-controller-tests
```

Expected: both executables print `PASS`.

- [ ] **Step 9: Commit the pure serving state**

```bash
git add 'Barrier City/Interaction/CafeOrderSession.swift' \
  'Barrier City/Interaction/RainbowSmoothieServingController.swift' \
  Tests/CafeOrderSessionTests.swift \
  Tests/RainbowSmoothieServingControllerTests.swift
git commit -m "feat: add smoothie serving state machine"
```

---

### Task 3: Install one hidden smoothie on a deterministic BarTable anchor

**Files:**
- Create: `Barrier City/Interaction/RainbowSmoothiePlacement.swift`
- Create: `Barrier City/Interaction/RainbowSmoothiePresenter.swift`
- Create: `Tests/RainbowSmoothiePlacementTests.swift`
- Modify: `Barrier City/ImmersiveSceneCatalog.swift:1-3`
- Modify: `Tests/ImmersiveSceneCatalogTests.swift:8-24`

**Interfaces:**
- Consumes: `RainbowSmoothie.usdz`, the `Indoor` entity, and its named `BarTable` entity.
- Produces: pure `RainbowSmoothiePlacement`, `ServingPlacementTuning`, and a `RainbowSmoothiePresenter` conforming to `RainbowSmoothiePresenting`.

- [ ] **Step 1: Write the failing placement math test**

Create `Tests/RainbowSmoothiePlacementTests.swift`:

```swift
import Foundation

private func expectNear(_ actual: Float, _ expected: Float, _ message: String) {
    guard abs(actual - expected) < 0.0001 else {
        fatalError("FAIL: \(message) expected \(expected), got \(actual)")
    }
}

@main
struct RainbowSmoothiePlacementTests {
    static func main() {
        let position = RainbowSmoothiePlacement.counterPosition(
            minimum: SIMD3<Float>(-2, 0, -1),
            maximum: SIMD3<Float>(2, 1, 1))
        expectNear(position.x, -0.8, "30 percent from left targets empty counter")
        expectNear(position.y, 1.01, "anchor clears the counter surface")
        expectNear(position.z, 0, "anchor stays centered in counter depth")
        expectNear(
            RainbowSmoothiePlacement.uniformScale(assetHeight: 0.56),
            0.5,
            "smoothie normalizes to 28 cm height")
        expectNear(
            RainbowSmoothiePlacement.uniformScale(assetHeight: 0),
            1,
            "invalid bounds preserve authored scale")
        print("PASS: RainbowSmoothiePlacementTests")
    }
}
```

- [ ] **Step 2: Run the placement test to verify RED**

Run:

```bash
xcrun swiftc 'Barrier City/Interaction/RainbowSmoothiePlacement.swift' \
  Tests/RainbowSmoothiePlacementTests.swift \
  -o /tmp/rainbow-smoothie-placement-tests
```

Expected: compilation fails because the placement file does not exist.

- [ ] **Step 3: Implement centralized placement tuning and math**

Create `RainbowSmoothiePlacement.swift`:

```swift
import Foundation

enum ServingPlacementTuning {
    static let counterFractionFromMinimumX: Float = 0.30
    static let counterDepthFraction: Float = 0.50
    static let surfaceClearance: Float = 0.01
    static let targetSmoothieHeight: Float = 0.28
}

enum RainbowSmoothiePlacement {
    static func counterPosition(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>
    ) -> SIMD3<Float> {
        let extent = maximum - minimum
        return SIMD3(
            minimum.x + extent.x * ServingPlacementTuning.counterFractionFromMinimumX,
            maximum.y + ServingPlacementTuning.surfaceClearance,
            minimum.z + extent.z * ServingPlacementTuning.counterDepthFraction)
    }

    static func uniformScale(assetHeight: Float) -> Float {
        guard assetHeight > 0.0001 else { return 1 }
        return ServingPlacementTuning.targetSmoothieHeight / assetHeight
    }
}
```

- [ ] **Step 4: Verify placement math is GREEN**

Run:

```bash
xcrun swiftc 'Barrier City/Interaction/RainbowSmoothiePlacement.swift' \
  Tests/RainbowSmoothiePlacementTests.swift \
  -o /tmp/rainbow-smoothie-placement-tests
/tmp/rainbow-smoothie-placement-tests
```

Expected: prints `PASS: RainbowSmoothiePlacementTests`.

- [ ] **Step 5: Expand the scene/asset contract test**

Add catalog names:

```swift
enum ImmersiveSceneCatalog {
    static let outdoor = "Outdoor"
    static let indoor = "Indoor"
    static let rainbowSmoothie = "RainbowSmoothie"
    static let barTable = "BarTable"
}
```

Extend `ImmersiveSceneCatalogTests.main()` after the existing Outdoor check:

```swift
let indoorAsset = assetDirectory
    .appendingPathComponent(ImmersiveSceneCatalog.indoor)
    .appendingPathExtension("usda")
let smoothieAsset = assetDirectory
    .appendingPathComponent(ImmersiveSceneCatalog.rainbowSmoothie)
    .appendingPathExtension("usdz")
guard FileManager.default.fileExists(atPath: smoothieAsset.path) else {
    fail("configured smoothie has no USDZ asset: \(smoothieAsset.path)")
}
guard let indoorSource = try? String(contentsOf: indoorAsset, encoding: .utf8),
      indoorSource.contains("\"\(ImmersiveSceneCatalog.barTable)\"") else {
    fail("Indoor scene does not preserve the named BarTable contract")
}
```

- [ ] **Step 6: Run the expanded asset contract test**

Run:

```bash
xcrun swiftc 'Barrier City/ImmersiveSceneCatalog.swift' Tests/ImmersiveSceneCatalogTests.swift -o /tmp/immersive-scene-catalog-tests
/tmp/immersive-scene-catalog-tests 'Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets'
```

Expected: both commands exit 0.

- [ ] **Step 7: Implement the one-entity RealityKit presenter**

Create `RainbowSmoothiePresenter.swift`:

```swift
import RealityKit

@MainActor
final class RainbowSmoothiePresenter: RainbowSmoothiePresenting {
    private(set) var smoothieEntity: Entity?
    private var servingAnchor: Entity?

    var isInstalled: Bool {
        smoothieEntity != nil && servingAnchor?.parent != nil
    }

    @discardableResult
    func install(smoothie: Entity?, in indoorMap: Entity) -> Bool {
        reset()
        guard let smoothie,
              let barTable = indoorMap.findEntity(named: ImmersiveSceneCatalog.barTable) else {
            return false
        }

        let barBounds = barTable.visualBounds(relativeTo: barTable)
        let anchor = Entity()
        anchor.name = "BarTableServingAnchor"
        anchor.position = RainbowSmoothiePlacement.counterPosition(
            minimum: barBounds.min,
            maximum: barBounds.max)
        barTable.addChild(anchor)

        let authoredBounds = smoothie.visualBounds(relativeTo: smoothie)
        let scale = RainbowSmoothiePlacement.uniformScale(
            assetHeight: authoredBounds.extents.y)
        smoothie.scale = SIMD3(repeating: scale)
        anchor.addChild(smoothie)
        let scaledBounds = smoothie.visualBounds(relativeTo: anchor)
        smoothie.position.y -= scaledBounds.min.y
        smoothie.isEnabled = false

        servingAnchor = anchor
        smoothieEntity = smoothie
        return true
    }

    func revealAtCounter() -> Bool {
        guard isInstalled, let smoothieEntity else { return false }
        smoothieEntity.isEnabled = true
        return true
    }

    func reset() {
        smoothieEntity?.removeFromParent()
        servingAnchor?.removeFromParent()
        smoothieEntity = nil
        servingAnchor = nil
    }
}
```

This file owns the only runtime `RainbowSmoothie` entity. Do not clone it in `revealAtCounter()`.

- [ ] **Step 8: Parse and build-check the presenter with the app target**

Run:

```bash
xcrun swiftc -parse 'Barrier City/Interaction/RainbowSmoothiePresenter.swift' \
  'Barrier City/Interaction/RainbowSmoothiePlacement.swift'
xcodebuild -project 'Barrier City.xcodeproj' -scheme 'Barrier City' \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/barrier-city-smoothie-presenter \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: parse exits 0 and the app build succeeds with the exact presenter interface defined above.

- [ ] **Step 9: Commit the asset and presenter boundary**

```bash
git add 'Barrier City/Interaction/RainbowSmoothiePlacement.swift' \
  'Barrier City/Interaction/RainbowSmoothiePresenter.swift' \
  'Barrier City/ImmersiveSceneCatalog.swift' \
  Tests/RainbowSmoothiePlacementTests.swift \
  Tests/ImmersiveSceneCatalogTests.swift
git commit -m "feat: place one smoothie on the cafe counter"
```

---

### Task 4: Make NPC speech consume session state and queue pickup audio exactly once

**Files:**
- Create: `Barrier City/Dialogue/CafeOrderDialogueContext.swift`
- Create: `Barrier City/Dialogue/OrderReadyAnnouncementGate.swift`
- Create: `Tests/OrderReadyAnnouncementGateTests.swift`
- Modify: `Barrier City/Dialogue/NPCDialogueController.swift:83-177,325-376,500-735`

**Interfaces:**
- Consumes: `CafeOrderSession.phase` and `RainbowSmoothieFulfillmentContext` from Task 1.
- Produces: `NPCDialogueController.init(orderSession:accessibilityAttitude:clerkPersonality:)` with a temporary default session for source compatibility, `requestOrderReadyAnnouncement()`, `deliverPendingOrderReadyAnnouncementIfPossible()`, and `blocksConversationForOrderReadyAnnouncement`.

- [ ] **Step 1: Write the failing exactly-once gate test**

Create `Tests/OrderReadyAnnouncementGateTests.swift`:

```swift
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

@main
struct OrderReadyAnnouncementGateTests {
    static func main() {
        var immediate = OrderReadyAnnouncementGate()
        expect(immediate.request(isChannelBusy: false) == .speakNow, "idle channel speaks now")
        expect(immediate.request(isChannelBusy: false) == .ignored, "immediate request is exactly once")

        var queued = OrderReadyAnnouncementGate()
        expect(queued.request(isChannelBusy: true) == .queued, "busy channel queues")
        expect(!queued.takePendingIfAvailable(isChannelBusy: true), "busy channel cannot drain")
        expect(queued.takePendingIfAvailable(isChannelBusy: false), "idle channel drains once")
        expect(!queued.takePendingIfAvailable(isChannelBusy: false), "drained queue does not repeat")

        queued.reset()
        expect(queued.request(isChannelBusy: false) == .speakNow, "new session can announce")
        print("PASS: OrderReadyAnnouncementGateTests")
    }
}
```

- [ ] **Step 2: Run the gate test to verify RED**

Run:

```bash
xcrun swiftc 'Barrier City/Dialogue/OrderReadyAnnouncementGate.swift' \
  Tests/OrderReadyAnnouncementGateTests.swift \
  -o /tmp/order-ready-announcement-gate-tests
```

Expected: compilation fails because the gate file does not exist.

- [ ] **Step 3: Implement the pure gate**

Create `OrderReadyAnnouncementGate.swift`:

```swift
struct OrderReadyAnnouncementGate {
    enum RequestResult: Equatable {
        case speakNow
        case queued
        case ignored
    }

    private var pending = false
    private var consumed = false

    var hasPendingAnnouncement: Bool { pending && !consumed }

    mutating func request(isChannelBusy: Bool) -> RequestResult {
        guard !consumed, !pending else { return .ignored }
        if isChannelBusy {
            pending = true
            return .queued
        }
        consumed = true
        return .speakNow
    }

    mutating func takePendingIfAvailable(isChannelBusy: Bool) -> Bool {
        guard pending, !consumed, !isChannelBusy else { return false }
        pending = false
        consumed = true
        return true
    }

    mutating func reset() {
        pending = false
        consumed = false
    }
}
```

- [ ] **Step 4: Verify the gate test is GREEN**

Run:

```bash
xcrun swiftc 'Barrier City/Dialogue/OrderReadyAnnouncementGate.swift' \
  Tests/OrderReadyAnnouncementGateTests.swift \
  -o /tmp/order-ready-announcement-gate-tests
/tmp/order-ready-announcement-gate-tests
```

Expected: prints `PASS: OrderReadyAnnouncementGateTests`.

- [ ] **Step 5: Map the app phase to DialogueKit without duplicating app state**

Create `CafeOrderDialogueContext.swift`:

```swift
import DialogueKit

extension CafeOrderPhase {
    var dialogueFulfillmentContext: RainbowSmoothieFulfillmentContext {
        switch self {
        case .notOrdered: .orderingAllowed
        case .preparing: .preparing
        case .readyAtCounter: .readyAtCounter
        case .failed: .failed
        }
    }
}
```

- [ ] **Step 6: Inject the session and pass its state through both dialogue paths**

Add the session property and make it the first initializer parameter:

```swift
private let orderSession: CafeOrderSession
private var fulfillmentContext: RainbowSmoothieFulfillmentContext {
    orderSession.phase.dialogueFulfillmentContext
}

init(
    orderSession: CafeOrderSession = CafeOrderSession(),
    accessibilityAttitude: AccessibilityAttitude = .ableist,
    clerkPersonality: ClerkPersonality? = nil
) {
    self.orderSession = orderSession
}
```

Insert `self.orderSession = orderSession` before the existing `self.accessibilityAttitude = accessibilityAttitude` assignment; retain the remaining voice and orchestrator construction unchanged.

Change the legacy orchestrator call in `respond(to:)`:

```swift
let result = await orchestrator.handle(
    utterance: utterance,
    history: history,
    fulfillmentContext: fulfillmentContext,
    onSentence: { pair.continuation.yield($0) })
```

In `.inputTranscriptDone`, stop the Realtime local mission reducer from collecting a second order after the app session leaves `notOrdered`:

```swift
let orderDecision: RainbowSmoothieOrderDecision
if fulfillmentContext.allowsOrderCompletion {
    orderDecision = realtimeMission.observe(userTranscript: transcript)
} else {
    orderDecision = .continueConversation
}
```

This replaces the existing unconditional `realtimeMission.observe(userTranscript:)` line. It is the deterministic Realtime duplicate guard; prompt wording alone is not sufficient.

Change `realtimeInstructions(for:orderDecision:)` so every session start/update receives the same state while preserving the response-specific slot guide:

```swift
private func realtimeInstructions(
    for climate: SocialClimate,
    orderDecision: RainbowSmoothieOrderDecision = .continueConversation
) -> String {
    """
    \(RealtimeConversationGuide().instructions(
        persona: Self.makePersona(
            accessibilityAttitude: accessibilityAttitude,
            clerkPersonality: clerkPersonality
        ),
        climate: climate,
        fulfillmentContext: fulfillmentContext
    ))

    # App-owned order state for this response
    \(orderDecision.promptGuide)
    """
}
```

The fulfillment context is session-wide; the order decision is the current transcript's slot result.

- [ ] **Step 7: Add deterministic ready TTS and subtitle delivery**

Add these members near the controller's other task and state fields:

```swift
private static let orderReadyLine = "주문하신 레인보우 스무디 나왔습니다. 카운터에서 가져가 주세요."
private var orderReadyAnnouncementGate = OrderReadyAnnouncementGate()
private var orderReadyAnnouncementTask: Task<Void, Never>?

var blocksConversationForOrderReadyAnnouncement: Bool {
    orderReadyAnnouncementTask != nil || orderReadyAnnouncementGate.hasPendingAnnouncement
}

func requestOrderReadyAnnouncement() {
    let busy = isEncounterActive || status != .idle || orderReadyAnnouncementTask != nil
    switch orderReadyAnnouncementGate.request(isChannelBusy: busy) {
    case .speakNow:
        startOrderReadyAnnouncement()
    case .queued, .ignored:
        break
    }
}

func deliverPendingOrderReadyAnnouncementIfPossible() {
    let busy = isEncounterActive || status != .idle || orderReadyAnnouncementTask != nil
    guard orderReadyAnnouncementGate.takePendingIfAvailable(isChannelBusy: busy) else { return }
    startOrderReadyAnnouncement()
}

private func startOrderReadyAnnouncement() {
    guard orderReadyAnnouncementTask == nil else { return }
    orderReadyAnnouncementTask = Task { @MainActor [weak self] in
        guard let self else { return }
        self.status = .speaking
        self.npcSubtitle = Self.orderReadyLine
        await self.voice.speak(Self.orderReadyLine) { [weak self] line in
            self?.npcSubtitle = line
        }
        guard !Task.isCancelled else { return }
        self.status = .idle
        self.orderReadyAnnouncementTask = nil
    }
}
```

At the start of `reset()`, cancel/clear the ready speech before `cancelEncounter()` stops the shared voice:

```swift
orderReadyAnnouncementTask?.cancel()
orderReadyAnnouncementTask = nil
orderReadyAnnouncementGate.reset()
cancelEncounter()
```

The subtitle is assigned before awaiting TTS, so a TTS transport failure does not erase the ready fact or visible line.

- [ ] **Step 8: Run focused tests and a compile check**

Run:

```bash
/tmp/order-ready-announcement-gate-tests
swift test --package-path Packages/DialogueKit --filter 'PromptBuilderTests|DialogueOrchestratorTests'
xcodebuild -project 'Barrier City.xcodeproj' -scheme 'Barrier City' \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/barrier-city-smoothie-dialogue \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: gate and package tests pass and the app build succeeds. The default session keeps existing `NPCDialogueController()` call sites source-compatible until Task 5 injects the shared AppModel-owned session.

- [ ] **Step 9: Commit the state-aware dialogue boundary**

```bash
git add 'Barrier City/Dialogue/CafeOrderDialogueContext.swift' \
  'Barrier City/Dialogue/OrderReadyAnnouncementGate.swift' \
  'Barrier City/Dialogue/NPCDialogueController.swift' \
  Tests/OrderReadyAnnouncementGateTests.swift
git commit -m "feat: queue state-aware smoothie pickup speech"
```

---

### Task 5: Wire Indoor preload, post-TTS order routing, and teardown

**Files:**
- Modify: `Barrier City/AppModel.swift:30-55`
- Modify: `Barrier City/Interaction/SceneSwitcher.swift:14-151`
- Modify: `Barrier City/NPC/NPCClerkController.swift:72-230,490-520`
- Modify: `Barrier City/ImmersiveView.swift:219-239`

**Interfaces:**
- Consumes: all interfaces from Tasks 1-4 plus the existing post-audio `.orderPlaced` mission event.
- Produces: a single `AppModel` dependency graph, hidden Indoor preload, one serving timer per session, automatic ready speech, and complete reset ordering.

- [ ] **Step 1: Add the dependency graph to `AppModel`**

Replace the current dialogue/clerk properties and initializer setup with:

```swift
let cafeOrderSession: CafeOrderSession
let rainbowSmoothiePresenter: RainbowSmoothiePresenter
let rainbowSmoothieServing: RainbowSmoothieServingController
let npcDialogue: NPCDialogueController
let npcClerk: NPCClerkController

init() {
    let orderSession = CafeOrderSession()
    let presenter = RainbowSmoothiePresenter()
    let dialogue = NPCDialogueController(orderSession: orderSession)
    let serving = RainbowSmoothieServingController(
        session: orderSession,
        presenter: presenter,
        onReady: { [weak dialogue] in
            dialogue?.requestOrderReadyAnnouncement()
        })

    cafeOrderSession = orderSession
    rainbowSmoothiePresenter = presenter
    rainbowSmoothieServing = serving
    npcDialogue = dialogue
    npcClerk = NPCClerkController(
        dialogue: dialogue,
        smoothieServing: serving)

    WheelchairComponent.registerComponent()
    WheelchairMovementSystem.registerSystem()
}
```

- [ ] **Step 2: Preload the optional smoothie while preparing Indoor**

Add `smoothie` to the prepared value:

```swift
private struct PreparedIndoorScene {
    let visible: Entity
    let collision: Entity
    let collisionShapeCount: Int
    let smoothie: Entity?
}
```

Load it after the visible Indoor entity and before returning:

```swift
let smoothie = try? await Entity(
    named: ImmersiveSceneCatalog.rainbowSmoothie,
    in: realityKitContentBundle)
try Task.checkCancellation()

return PreparedIndoorScene(
    visible: visible,
    collision: collision,
    collisionShapeCount: collisionShapeCount,
    smoothie: smoothie)
```

The smoothie load is intentionally optional: Indoor may still appear, but serving records `failed` and never invents a fallback location.

- [ ] **Step 3: Install hidden and begin the order generation in the atomic Indoor commit**

Immediately after `app.npcClerk.enterIndoor(...)` and the following transition-current guard, add:

```swift
app.rainbowSmoothiePresenter.install(
    smoothie: prepared.smoothie,
    in: prepared.visible)
app.rainbowSmoothieServing.enterIndoor()
```

This occurs while `prepared.visible.isEnabled == false`, so the presenter's own `isEnabled = false` is established before the first visible Indoor frame.

- [ ] **Step 4: Route the existing order event and drain queued speech in `NPCClerkController`**

Add a serving dependency:

```swift
private let smoothieServing: RainbowSmoothieServingController

init(
    dialogue: NPCDialogueController,
    smoothieServing: RainbowSmoothieServingController
) {
    self.dialogue = dialogue
    self.smoothieServing = smoothieServing
}
```

In `handleDialogueSignals()`, preserve the quest event and add the serving call only in `.orderPlaced`:

```swift
case .orderPlaced:
    GuideFlowModel.shared.handleQuestEvent(.npcHelpDone)
    smoothieServing.acceptOrder()
    pendingOrderConversationEnd = true
    finishAcceptedOrderPresentationIfReady()
```

At the start of `update(deltaTime:appModel:)`, before calculating `isTalkAvailable`, give queued audio a drain point:

```swift
dialogue.deliverPendingOrderReadyAnnouncementIfPossible()
```

Add the ready channel to the availability condition:

```swift
isTalkAvailable = (phase == .working || phase == .orderAccepted)
    && playerDistance <= NPCClerkTuning.detectionRadius
    && GuideFlowModel.shared.allowsNPCOrderConversation
    && !dialogue.isBusy
    && !dialogue.blocksConversationForOrderReadyAnnouncement
```

Because `.orderPlaced` is already published only after the final order-confirmation audio ends, `smoothieServing.acceptOrder()` is the required 10-second timer anchor; do not move it into transcript or intent handling.

- [ ] **Step 5: Reset serving before clerk/dialogue teardown**

In `ImmersiveView.onDisappear`, immediately before `model.npcClerk.resetForOutdoor()` add:

```swift
model.rainbowSmoothieServing.resetForOutdoor()
model.npcClerk.resetForOutdoor()
```

Keep `NPCClerkController.resetForOutdoor()` responsible for `dialogue.reset()`. The explicit order above cancels the preparation task and removes the entity before voice/dialogue state is cleared.

- [ ] **Step 6: Build the fully wired app**

Run:

```bash
xcodebuild -project 'Barrier City.xcodeproj' -scheme 'Barrier City' \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/barrier-city-rainbow-smoothie-serving \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Run all new focused regressions**

Run:

```bash
xcrun swiftc 'Barrier City/Interaction/CafeOrderSession.swift' Tests/CafeOrderSessionTests.swift -o /tmp/cafe-order-session-tests
/tmp/cafe-order-session-tests
xcrun swiftc 'Barrier City/Interaction/CafeOrderSession.swift' \
  'Barrier City/Interaction/RainbowSmoothieServingController.swift' \
  Tests/RainbowSmoothieServingControllerTests.swift \
  -o /tmp/rainbow-smoothie-serving-controller-tests
/tmp/rainbow-smoothie-serving-controller-tests
xcrun swiftc 'Barrier City/Interaction/RainbowSmoothiePlacement.swift' Tests/RainbowSmoothiePlacementTests.swift -o /tmp/rainbow-smoothie-placement-tests
/tmp/rainbow-smoothie-placement-tests
xcrun swiftc 'Barrier City/Dialogue/OrderReadyAnnouncementGate.swift' Tests/OrderReadyAnnouncementGateTests.swift -o /tmp/order-ready-announcement-gate-tests
/tmp/order-ready-announcement-gate-tests
xcrun swiftc 'Barrier City/ImmersiveSceneCatalog.swift' Tests/ImmersiveSceneCatalogTests.swift -o /tmp/immersive-scene-catalog-tests
/tmp/immersive-scene-catalog-tests 'Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets'
swift test --package-path Packages/DialogueKit
```

Expected: every standalone executable prints `PASS`, the asset contract exits 0, and all DialogueKit tests pass.

- [ ] **Step 8: Commit the app integration**

```bash
git add 'Barrier City/AppModel.swift' \
  'Barrier City/Interaction/SceneSwitcher.swift' \
  'Barrier City/NPC/NPCClerkController.swift' \
  'Barrier City/ImmersiveView.swift'
git commit -m "feat: serve rainbow smoothie after clerk order"
```

---

### Task 6: Directly accept timing, placement, memory, duplication, and reset

**Files:**
- Modify only if visual evidence requires it: `Barrier City/Interaction/RainbowSmoothiePlacement.swift`
- Verify: all scoped files from Tasks 1-5

**Interfaces:**
- Consumes: the completed integrated feature and a running visionOS Simulator; consumes Vision Pro when available.
- Produces: fresh automated evidence plus direct immersive acceptance evidence for the exact user flow.

- [ ] **Step 1: Verify the diff contains only scoped work**

Run:

```bash
git diff --check
git status --short
git log --oneline --decorate -8
```

Expected: no whitespace errors; unrelated Xcode/Reality Composer/design-asset changes remain unstaged and uncommitted.

- [ ] **Step 2: Run the complete automated regression set again**

Run the exact focused commands from Task 5 Step 7, then:

```bash
xcrun swiftc 'Barrier City/Interaction/OutdoorSessionStart.swift' Tests/OutdoorSessionStartTests.swift -o /tmp/outdoor-session-start-tests
/tmp/outdoor-session-start-tests
xcodebuild -project 'Barrier City.xcodeproj' -scheme 'Barrier City' \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/barrier-city-rainbow-smoothie-final \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: all tests pass and the build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Accept the exact Simulator flow**

Launch the `Barrier City` scheme on visionOS Simulator and perform this recorded checklist:

```text
[ ] Enter Indoor; no smoothie is visible before ordering.
[ ] Complete one verbal order for exactly one Rainbow Smoothie.
[ ] Start a stopwatch when the clerk's final “please wait / I will notify you” audio ends.
[ ] At 9 seconds the smoothie is still hidden.
[ ] At 10 seconds one smoothie appears, with no second entity or pop-in before the deadline.
[ ] The smoothie sits on the empty left-side counter area shown in the reference image.
[ ] It does not penetrate or float above the surface and does not overlap the display case or payment device.
[ ] The clerk says exactly once: 주문하신 레인보우 스무디 나왔습니다. 카운터에서 가져가 주세요.
[ ] The same sentence appears as a subtitle even if cloud TTS is unavailable.
[ ] A conversation during preparation reports the existing order as preparing.
[ ] A conversation after reveal reports the existing drink as ready at the counter.
[ ] Repeating order language does not restart timing, add a smoothie, or repeat the automatic announcement.
[ ] Exiting during preparation and re-entering leaves no stale smoothie or delayed announcement.
```

- [ ] **Step 4: Tune only the centralized placement constants if visual acceptance fails**

Adjust only these constants from `ServingPlacementTuning`, one at a time, based on the Simulator view:

```swift
static let counterFractionFromMinimumX: Float = 0.30
static let counterDepthFraction: Float = 0.50
static let surfaceClearance: Float = 0.01
static let targetSmoothieHeight: Float = 0.28
```

For every changed value, update the corresponding exact expected value in `RainbowSmoothiePlacementTests.swift`, rerun `/tmp/rainbow-smoothie-placement-tests`, rebuild, and repeat Task 6 Step 3. Do not add a second placement override elsewhere.

- [ ] **Step 5: Repeat spatial and audio acceptance on Vision Pro when hardware is available**

Verify from a seated wheelchair-height viewpoint:

```text
[ ] Smoothie scale reads as a believable single drink.
[ ] Counter contact and empty-area placement remain correct with binocular depth.
[ ] The ready speech is audible, non-overlapping, and occurs once.
[ ] Leaving/re-entering the immersive space resets state and cancels delayed work.
```

If Vision Pro is unavailable, report Simulator acceptance as complete and explicitly leave hardware acceptance unverified.

- [ ] **Step 6: Commit any evidence-driven placement adjustment**

Only when Task 6 Step 4 changed tracked source/test files:

```bash
git add 'Barrier City/Interaction/RainbowSmoothiePlacement.swift' \
  Tests/RainbowSmoothiePlacementTests.swift
git commit -m "fix: tune smoothie counter placement"
```

- [ ] **Step 7: Perform final scope and requirement review**

Run:

```bash
git diff --check develop...HEAD
git diff --stat develop...HEAD
git status --short
rg -n 'T[B]D|T[O]DO|implement[ ]later|fill[ ]in details' \
  docs/superpowers/plans/2026-08-18-rainbow-smoothie-serving.md \
  'Barrier City/Interaction' 'Barrier City/Dialogue' Packages/DialogueKit/Sources/DialogueKit
```

Expected: the feature diff contains the design/plan and scoped implementation only; the search finds no new placeholder text in the implementation; unrelated user files are still untouched.

Final report must separate:

```text
Automated: standalone state/serving/placement/gate/catalog tests, DialogueKit tests, visionOS Simulator build
Directly verified: Simulator timing, placement, one-shot speech, preparing/ready memory, duplicate behavior, reset
Still unverified: Vision Pro acceptance, if no device run was performed
```
