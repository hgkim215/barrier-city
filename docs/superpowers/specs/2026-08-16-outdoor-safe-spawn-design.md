# Outdoor Safe Spawn Design

## Goal

Respawn the wheelchair at the farthest supported point from the cafe door on
the existing straight approach line, without placing any part of the chair
outside the collision floor. Preserve the earlier requirement that the door
prompt appears only after roughly one or two steps of approach.

## Root Cause

`OutdoorSessionStart.positionOutsideCafe` currently extrapolates 3.0 m from
the door without checking the floor boundary. The authored door is near
`z = -5.889`, while the fallback collision floor is a 16 m square centered at
the origin and ends at `z = -8`. The resulting start position near
`z = -8.889` has no ground under the wheelchair support rays, so the movement
system applies falling gravity.

## Design

### Shared Ground Boundary

Move the fallback floor size into `InteractionTuning` as the shared source of
truth. `ImmersiveView` uses that value to build the collision box, and the
spawn calculation receives the same half extent.

The collision floor is 16 m square, with horizontal bounds from -8 m to 8 m.
Inset those bounds by 0.5 m for the spawn calculation. This margin is larger
than the wheelchair's approximately 0.42 m longitudinal body extent and its
collision skin, keeping the entire chair and its support rays on the floor.

### Farthest Safe Point

Keep the existing outward direction from the cafe center through the door.
Treat that direction as a ray beginning at the door and find its last point
inside the inset ground square. That ray exit is the farthest supported point
from the door while preserving a direct, front-facing approach route.

For the current asset, the negative-Z inset edge is `z = -7.5`, so the start
is about 1.6 m from the authored door rather than the unsupported 3.0 m point.
If a malformed scene produces no forward ray intersection, clamp the door
position into the inset square as a safe fallback.

### Door Prompt Distance

Reduce the door trigger radius from 2.5 m to 1.1 m. At the current safe spawn
distance, the prompt remains hidden initially and becomes eligible after
approximately 0.5 m of movement toward the door. The existing guide lock and
0.6 m panel forward offset remain unchanged.

## Verification

Automated regression tests will verify:

1. A door near the negative-Z floor edge produces a spawn at the inset edge,
   not beyond the collision floor.
2. Diagonal outward rays choose the correct last point within the inset square.
3. Degenerate cafe/door coordinates retain the authored fallback direction.
4. The real interaction flow starts outside the 1.1 m trigger and enters it
   after a 0.5 m approach.
5. The fallback collision floor and spawn calculation consume the same 16 m
   tuning value.

Run all standalone regressions, DialogueKit tests, and a generic visionOS
Simulator build. Final spatial acceptance remains a direct Simulator or
Vision Pro check because build success cannot prove perceived spawn placement.

## Scope

This change does not extend invisible ground, alter the Outdoor asset, change
wheelchair physics, move the cafe door, modify guide progression, or affect
the indoor spawn, kiosk, NPC dialogue, and scene-transition behavior.
