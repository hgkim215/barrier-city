# Eye-Front Door Prompt Design

## Goal

When the wheelchair enters the cafe-door trigger, show the entrance question
directly in front of the user at a comfortable viewing distance, with working
`예` and `아니요` controls. The prompt must not be hidden by the door or wall.

## Root Cause

The entry prompt is currently parented to `worldRoot`, the same root that the
wheelchair movement system translates and rotates to simulate travel. It is
then placed at the door and pulled only 0.6 m toward the user.

The door trigger activates at 1.1 m. At that moment, the current placement can
leave the 760-point-wide prompt only about 0.5 m from the user while it remains
coupled to the moving door geometry. This combination can put the prompt in an
uncomfortable near field, outside the useful view, or behind intersecting
geometry. A yaw billboard changes orientation but does not make the prompt a
user-centered interface.

## Design

### User-Relative Prompt Root

Attach the entry prompt directly to the `RealityView` content root instead of
`worldRoot`. The app keeps the user at the immersive origin and moves
`worldRoot` inversely for wheelchair travel, so a content-root entity remains
stable relative to the user while the cafe moves around it.

Keep the kiosk and NPC attachments under their existing parents. Only the cafe
entry prompt changes coordinate spaces.

### Centered Placement

When the active trigger is `.yesNoPrompt`, place the entry prompt at:

- X: `0.0 m`, centered horizontally
- Y: `1.45 m`, suitable for the seated eye line used by the existing guide
  fallback
- Z: `-1.2 m`, a comfortable distance directly in front of the user
- Orientation: identity, facing the user from the negative-Z direction

Define this as a pure `InteractionPromptPlacement.eyeFrontPosition` tuning
result so a standalone regression can verify the exact user-relative contract.
The previous door-surface offset is no longer used for the entry prompt.

### Visibility and Selection Flow

Preserve the existing proximity and guide rules:

1. The prompt remains hidden outside the 1.1 m door trigger.
2. Guide-locked phases continue to suppress environment interaction.
3. Entering the trigger in an active mission sets the door trigger active and
   enables the centered prompt.
4. `예` continues to call `SceneSwitcher.requestIndoorTransition()`.
5. `아니요` continues to dismiss the trigger until the user leaves the range
   and approaches again.
6. Scene-transition errors continue to appear in the same prompt.

The SwiftUI `EntryPromptView` and its button actions do not change, preserving
native gaze-and-pinch selection.

### Kiosk Isolation

The kiosk billboard fallback keeps its current world-space placement and
0.8 m surface offset. Moving the entry prompt must not change the real Indoor
`Screen/Plane` presentation or kiosk input state.

## Verification

Automated verification will cover:

1. The eye-front position is exactly `(0, 1.45, -1.2)`.
2. Initial door proximity remains hidden and a 0.5 m approach activates it.
3. `아니요` dismissal and re-entry behavior remains intact.
4. Kiosk billboard fallback placement remains unchanged.
5. All standalone regressions, DialogueKit tests, and the generic visionOS
   Simulator build pass.

Direct Simulator or Vision Pro acceptance must confirm that the panel appears
in front of the user's eyes, is not occluded by the door, and both buttons can
be selected. Automated build success cannot establish those spatial facts.

## Scope

This change does not alter the door trigger radius, safe outdoor spawn, guide
progression, wheelchair physics, Outdoor or Indoor assets, scene transition,
kiosk screen, NPC flow, or dialogue behavior. The user's existing unstaged
Xcode project-file change remains untouched.
