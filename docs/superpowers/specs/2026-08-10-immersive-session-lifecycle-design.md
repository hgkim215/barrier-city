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

The state accepts lifecycle events for beginning and completing an open or
close operation plus view appearance and disappearance. Invalid or stale events
are ignored. In particular, a disappear callback received while a new session
is already `opening` must not close the new session.

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

Before calling `openImmersiveSpace`, send `beginOpen`. Map `.opened` to
`openSucceeded`; map cancellation and errors to `openFailed` and preserve the
existing error copy.

Before calling `dismissImmersiveSpace`, send `beginClose`. After the async call
returns, send `closeSucceeded`. This explicit completion makes the control
window return to `체험 시작` even if `onDisappear` does not drive the update.

### View Lifecycle Reconciliation

`ImmersiveView.onAppear` sends `appeared`, and `onDisappear` sends
`disappeared`. These events reconcile system-driven entry or exit. The state
machine treats duplicate completion events as idempotent and ignores a stale
disappear callback while a newer open is in progress.

## Verification

Standalone regression tests will verify:

1. The normal open-close cycle returns to `closed` and `체험 시작`.
2. A second open succeeds after closing.
3. Cancellation and errors return to the start state.
4. System-driven disappearance closes an open session.
5. A stale disappearance does not cancel a new opening session.
6. Button labels and transition disabled state match every phase.

Then run the existing standalone regression suite, all 54 DialogueKit tests,
and the generic visionOS Simulator build. Manual acceptance must cover two full
start-exit cycles and confirm that each exit restores the start action.

## Scope

This change does not alter scene loading, outdoor or indoor spawn placement,
wheelchair physics, quest progression, NPC behavior, or immersive-space IDs.
