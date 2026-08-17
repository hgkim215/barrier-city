import Foundation
import simd

enum KioskHandSide: Hashable {
    case left
    case right
}

enum KioskReachTuning {
    static let frontRange: ClosedRange<Float> = 0.08...0.65
    static let horizontalMargin: Float = 0.12
    static let minimumMovement: Float = 0.08
    static let movementWindow: TimeInterval = 0.45
    static let dwellDuration: TimeInterval = 0.20
    static let cooldownDuration: TimeInterval = 1.0
    static let staleTimeout: TimeInterval = 0.25
}

/// A scale-independent world-space frame for the corrected kiosk display.
/// Coordinates returned by this type are physical meters along visible
/// screen-right, screen-up, and the screen's outward normal.
struct KioskScreenCoordinateFrame: Equatable {
    private let origin: SIMD3<Float>
    private let rightAxis: SIMD3<Float>
    private let upAxis: SIMD3<Float>
    private let normalAxis: SIMD3<Float>
    let halfSizeMeters: SIMD2<Float>

    init?(
        planeWorldTransform: simd_float4x4,
        localSurfaceCenter: SIMD3<Float>,
        localHalfSize: SIMD2<Float>,
        faceRotationRadians: Float
    ) {
        let planeRight = SIMD3<Float>(
            planeWorldTransform.columns.0.x,
            planeWorldTransform.columns.0.y,
            planeWorldTransform.columns.0.z)
        let planeUp = SIMD3<Float>(
            planeWorldTransform.columns.1.x,
            planeWorldTransform.columns.1.y,
            planeWorldTransform.columns.1.z)
        let planeNormal = SIMD3<Float>(
            planeWorldTransform.columns.2.x,
            planeWorldTransform.columns.2.y,
            planeWorldTransform.columns.2.z)
        let localValues = [
            localSurfaceCenter.x,
            localSurfaceCenter.y,
            localSurfaceCenter.z,
            localHalfSize.x,
            localHalfSize.y,
            faceRotationRadians,
        ]
        let rightScale = simd_length(planeRight)
        let upScale = simd_length(planeUp)
        let normalScale = simd_length(planeNormal)

        guard localValues.allSatisfy(\.isFinite),
              localHalfSize.x > 0,
              localHalfSize.y > 0,
              rightScale.isFinite,
              upScale.isFinite,
              normalScale.isFinite,
              rightScale > 0,
              upScale > 0,
              normalScale > 0 else {
            return nil
        }

        let uncorrectedRight = planeRight / rightScale
        let uncorrectedUp = planeUp / upScale
        let cosine = cosf(faceRotationRadians)
        let sine = sinf(faceRotationRadians)
        let correctedRight = cosine * uncorrectedRight + sine * uncorrectedUp
        let correctedUp = -sine * uncorrectedRight + cosine * uncorrectedUp
        let correctedRightLength = simd_length(correctedRight)
        let correctedUpLength = simd_length(correctedUp)
        guard correctedRightLength.isFinite,
              correctedUpLength.isFinite,
              correctedRightLength > 0,
              correctedUpLength > 0 else {
            return nil
        }

        let worldOrigin = planeWorldTransform * SIMD4<Float>(localSurfaceCenter, 1)
        guard worldOrigin.x.isFinite,
              worldOrigin.y.isFinite,
              worldOrigin.z.isFinite else {
            return nil
        }

        origin = SIMD3<Float>(worldOrigin.x, worldOrigin.y, worldOrigin.z)
        rightAxis = correctedRight / correctedRightLength
        upAxis = correctedUp / correctedUpLength
        normalAxis = planeNormal / normalScale
        halfSizeMeters = SIMD2<Float>(
            abs(cosine) * localHalfSize.x * rightScale
                + abs(sine) * localHalfSize.y * upScale,
            abs(sine) * localHalfSize.x * rightScale
                + abs(cosine) * localHalfSize.y * upScale)
    }

    func screenPosition(for worldPosition: SIMD3<Float>) -> SIMD3<Float> {
        let displacement = worldPosition - origin
        return SIMD3<Float>(
            simd_dot(displacement, rightAxis),
            simd_dot(displacement, upAxis),
            simd_dot(displacement, normalAxis))
    }
}

struct KioskReachAttemptDetector {
    private var origin: (position: SIMD3<Float>, time: TimeInterval)?
    private var armedAt: TimeInterval?
    private var lastSampleTime: TimeInterval?
    private var cooldownUntil: TimeInterval = -.infinity

    mutating func reset() {
        origin = nil
        armedAt = nil
        lastSampleTime = nil
        cooldownUntil = -.infinity
    }

    mutating func sample(
        position: SIMD3<Float>,
        timestamp: TimeInterval,
        isTracked: Bool,
        halfWidth: Float,
        halfHeight: Float
    ) -> Bool {
        let isStale = lastSampleTime.map {
            timestamp - $0 > KioskReachTuning.staleTimeout
        } ?? false
        if !isTracked || isStale {
            clearCandidate()
        }
        lastSampleTime = timestamp

        let isFinite = position.x.isFinite && position.y.isFinite && position.z.isFinite
            && halfWidth.isFinite && halfHeight.isFinite && timestamp.isFinite
        let isInsideAttemptVolume = isFinite
            && KioskReachTuning.frontRange.contains(position.z)
            && abs(position.x) <= halfWidth + KioskReachTuning.horizontalMargin
            && abs(position.y) <= halfHeight + KioskReachTuning.horizontalMargin

        guard isTracked, timestamp >= cooldownUntil, isInsideAttemptVolume else {
            clearCandidate()
            return false
        }

        guard let start = origin else {
            origin = (position, timestamp)
            return false
        }

        guard timestamp - start.time <= KioskReachTuning.movementWindow else {
            origin = (position, timestamp)
            armedAt = nil
            return false
        }

        let movedTowardScreen = start.position.z - position.z >= KioskReachTuning.minimumMovement
        let movedUpward = position.y - start.position.y >= KioskReachTuning.minimumMovement
        if (movedTowardScreen || movedUpward), armedAt == nil {
            armedAt = timestamp
        }

        guard let armedAt,
              timestamp - armedAt >= KioskReachTuning.dwellDuration else {
            return false
        }

        cooldownUntil = timestamp + KioskReachTuning.cooldownDuration
        clearCandidate()
        return true
    }

    private mutating func clearCandidate() {
        origin = nil
        armedAt = nil
    }
}
