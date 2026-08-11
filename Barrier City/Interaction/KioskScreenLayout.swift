enum KioskScreenLayout {
    static func uniformScale(
        planeSize: SIMD2<Float>,
        attachmentSize: SIMD2<Float>,
        fill: Float
    ) -> Float? {
        let values = [
            planeSize.x,
            planeSize.y,
            attachmentSize.x,
            attachmentSize.y,
            fill,
        ]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }

        return min(
            planeSize.x / attachmentSize.x,
            planeSize.y / attachmentSize.y) * fill
    }
}
