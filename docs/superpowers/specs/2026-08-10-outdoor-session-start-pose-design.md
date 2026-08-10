# Outdoor Session Start Pose Design

## Goal

Every entry into the immersive space starts a fresh outdoor experience at the
original wheelchair position, with the user facing the cafe entrance.

## Current Problem

`AppModel` lives for the application lifetime. `InteractionSetup.install` resets
the quest and interaction session, but it does not reset the wheelchair's
physical state. Re-entering the immersive space can therefore retain position,
heading, velocity, tilt, or a fallen state from the previous session.

The current outdoor heading is `0`. In the wheelchair coordinate convention,
heading `0` points toward negative Z, while the outdoor cafe entrance is located
near positive Z. The experience therefore begins facing away from the cafe.

## Design

### Session Reset

At the start of `InteractionSetup.install`, call `appModel.restart()` before
installing triggers, panels, and quest state. This uses the existing complete
wheelchair reset path to clear movement, input, collision, tilt, fall, and pose
state on every immersive-space entry.

### Outdoor Start Pose

The outdoor start position remains `(0, 0)`. After resolving the `DOOR1` entity,
calculate the heading from the start position toward the door center. If
`DOOR1` is unavailable, use the existing fallback center `(0, 15)`.

The heading calculation follows the movement engine convention where the local
forward vector is `(-sin(heading), -cos(heading))`. A cafe entrance on positive
Z therefore produces a heading of approximately pi radians, or 180 degrees.

Keep the pose calculation in a small pure helper so it can be tested without
RealityKit scene loading. `InteractionSetup` applies the returned position and
heading after `appModel.restart()`.

### Failure Handling

An unavailable or coincident door marker must not produce a NaN heading. The
helper uses the fallback cafe direction when the target distance is effectively
zero. Existing missing-marker logging remains unchanged.

## Verification

Automated regression tests will verify:

1. A door on positive Z produces a heading of pi radians.
2. An offset door produces a heading whose forward vector points at the door.
3. A coincident target uses the fallback cafe-facing heading.
4. The immersive installation path performs a wheelchair restart before
   applying the outdoor start pose.

After the tests pass, run the existing standalone regression suite,
`DialogueKit` tests, and a generic visionOS Simulator build. Manual acceptance
should confirm that leaving and re-entering starts at the outdoor origin without
retained fall state and with the cafe entrance centered ahead.

## Scope

This change does not alter indoor spawn behavior, scene geometry, movement
physics, quest progression, kiosk presentation, or NPC dialogue behavior.
