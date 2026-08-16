# Cafe Door Prompt Visibility Design

## Goal

Make the outdoor cafe entrance feel intentional: the wheelchair starts far
enough from the door that the user must approach it, and the entry prompt is
rendered in front of the door instead of being hidden by the door geometry.

## Current Problem

The outdoor start pose is only 1.25 m from the cafe door while the door trigger
radius is 2.5 m. The player therefore starts inside the trigger. In addition,
the yes/no entry panel uses a zero forward offset, placing it at the trigger
center on the door plane where the door or wall can occlude it.

## Design

### Outdoor Start Distance

Set `InteractionTuning.outdoorSpawnDistanceFromDoor` to 3.0 m while preserving
the existing 2.5 m trigger radius. The start pose remains outside the cafe and
faces the entrance through the existing `OutdoorSessionStart` calculation.
The player must travel approximately 0.5 m toward the door before the prompt
becomes eligible to appear.

This reintroduces the previously tested 3.0 m start distance because the user
has now explicitly selected approach-before-prompt behavior.

### Door Prompt Placement

Add a door-specific panel forward offset of 0.6 m to `InteractionTuning` and
pass it to the existing billboard placement path for yes/no prompts. The
billboard helper already computes the direction from the trigger toward the
player, so the offset moves the panel away from the door surface and toward
the user without changing its facing behavior.

Keep the kiosk panel's existing offset and placement path unchanged.

### Interaction Flow

The guide lock remains unchanged. The door prompt can appear only after the
active guide phase permits interaction. Once unlocked, the existing proximity
evaluation shows the prompt only after the player enters the 2.5 m radius.
Confirming the prompt continues to transition to the indoor scene.

## Verification

Automated regression tests will verify:

1. The outdoor start pose is 3.0 m outside the door.
2. The start distance is greater than the 2.5 m door trigger radius.
3. Moving 0.5 m toward the door reaches the prompt boundary.
4. The door prompt uses a positive 0.6 m player-facing offset while kiosk
   placement remains unchanged.

After the focused tests pass, run the complete standalone regression suite,
DialogueKit tests, and a visionOS Simulator build. Spatial acceptance still
requires the user to confirm on a simulator or device that the prompt is
visibly in front of the door and the approach distance feels natural.

## Scope

This change does not alter the authored Outdoor asset, door coordinates,
movement physics, guide progression, indoor spawn, kiosk presentation, NPC
dialogue, or scene-loading behavior. It preserves both the merged `develop`
functionality and the current branch's kiosk and quest functionality.
