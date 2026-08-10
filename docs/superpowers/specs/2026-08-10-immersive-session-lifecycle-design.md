# Immersive Session Lifecycle Design

## Goal

After the user selects `체험 종료`, the control window must return to the
`체험 시작` action and allow the immersive experience to open again. The same
state must remain correct when visionOS closes the immersive space outside the
control-window button.

## Root Cause

The control window reads `AppModel.isImmersive`, but the dismiss button only
awaits `dismissImmersiveSpace()`. The model changes back to `false` exclusively
from `ImmersiveView.onDisappear`. When that callback is delayed or omitted, the
control window remains on `체험 종료`, so the open action is no longer reachable.

The local `isImmersiveTransitioning` flag is a second source of truth owned by
`ControlPanelView`. Opening, closing, view appearance, and view disappearance
therefore do not share one lifecycle model.

## Design

### Shared State Machine

Add a pure `ImmersiveSessionState` with four phases:

- `closed`
- `opening`
- `open`
- `closing`

Each accepted open receives a monotonically increasing generation number. Async
open/close completions and each immersive view instance carry that number back
to the state. Results and disappearance callbacks from older generations are
ignored, including their shared Quest, interaction, NPC, and hand-tracking
teardown. This prevents a delayed callback from session A from changing or
tearing down a reopened session B.

The state exposes the button title and transition status:

| Phase | Button title | Disabled |
|---|---|---|
| `closed` | `체험 시작` | No |
| `opening` | `여는 중…` | Yes |
| `open` | `체험 종료` | No |
| `closing` | `종료 중…` | Yes |

`AppModel.isImmersive` becomes a computed compatibility property derived from
the session phase so existing hand-tracking and diagnostic behavior keeps the
same API without retaining a second mutable Boolean.

### Control Window Flow

Before calling `openImmersiveSpace`, begin an open and retain its generation.
Map `.opened` to a successful completion; map cancellation and errors to a
failed completion and preserve the existing error copy. A completion only
applies when its generation still owns the current opening operation.

Before calling `dismissImmersiveSpace`, begin a close and retain its generation.
After the async call returns, complete that generation. This explicit completion
makes the control window return to `체험 시작` even if `onDisappear` does not
drive the update.

### View Lifecycle Reconciliation

`ImmersiveView.onAppear` claims the current generation. `onDisappear` may update
state and run shared teardown only when its stored generation still matches the
latest session. Duplicate completions are idempotent; stale view callbacks are
side-effect free with respect to shared app state. Every disappearing view still
stops its own ARKit session before the ownership check so an obsolete hand
tracking provider cannot survive into the replacement session.

## Verification

Standalone regression tests will verify:

1. The normal open-close cycle returns to `closed` and `체험 시작`.
2. A second open succeeds after closing.
3. Cancellation and errors return to the start state.
4. System-driven disappearance closes an open session.
5. A stale disappearance after the replacement has appeared cannot close or
   tear down that replacement.
6. A stale async open result cannot mutate a newer session.
7. Button labels and transition disabled state match every phase.
8. Local ARKit shutdown occurs before the generation guard, while shared input
   cleanup occurs after it.

Then run the existing standalone regression suite, all 54 DialogueKit tests,
and the generic visionOS Simulator build. Manual acceptance must cover two full
start-exit cycles and confirm that each exit restores the start action.

## Scope

This change does not alter scene loading, outdoor or indoor spawn placement,
wheelchair physics, quest progression, NPC behavior, or immersive-space IDs.
