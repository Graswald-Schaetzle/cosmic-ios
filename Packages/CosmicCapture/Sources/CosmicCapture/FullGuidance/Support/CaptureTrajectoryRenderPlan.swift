import Foundation
import simd

struct CaptureTrajectoryRenderPlan: Sendable {
    static let maxPathPositions = 600
    static let maxFrustums = 48

    let pathPositions: [SIMD3<Float>]
    let frustumTransforms: [simd_float4x4]
    let style: CaptureTrajectoryRenderStyle

    static func make(
        trajectory: CaptureTrajectory,
        sceneRadiusM: Float,
        maxPathPositions: Int = maxPathPositions,
        maxFrustums: Int = maxFrustums
    ) -> CaptureTrajectoryRenderPlan {
        let pathPositions = uniformlySampled(
            trajectory.cameraPositions,
            limit: maxPathPositions
        )
        return CaptureTrajectoryRenderPlan(
            pathPositions: pathPositions,
            frustumTransforms: uniformlySampled(
                trajectory.arkitWorldFromCamera,
                limit: maxFrustums
            ),
            style: CaptureTrajectoryRenderStyle.make(
                sceneRadiusM: sceneRadiusM,
                trajectoryPositions: pathPositions
            )
        )
    }

    private static func uniformlySampled<Value>(
        _ values: [Value],
        limit: Int
    ) -> [Value] {
        guard limit > 0, values.count > limit else { return values }
        guard limit > 1 else { return [values[0]] }

        return (0..<limit).map { outputIndex in
            let sourceIndex = outputIndex * (values.count - 1) / (limit - 1)
            return values[sourceIndex]
        }
    }
}

struct CaptureTrajectoryRenderStyle: Equatable, Sendable {
    static let minimumFrustumDepthM: Float = 0.06
    static let maximumFrustumDepthM: Float = 0.75

    let frustumDepthM: Float
    let pathRadiusM: Float
    let frustumStrokeRadiusM: Float

    static func make(
        sceneRadiusM: Float,
        trajectoryPositions: [SIMD3<Float>]
    ) -> CaptureTrajectoryRenderStyle {
        let trajectoryRadiusM = boundingRadius(of: trajectoryPositions)
        let referenceRadiusM = max(sceneRadiusM, trajectoryRadiusM)
        let frustumDepthM = min(
            maximumFrustumDepthM,
            max(minimumFrustumDepthM, referenceRadiusM * 0.14)
        )
        return CaptureTrajectoryRenderStyle(
            frustumDepthM: frustumDepthM,
            pathRadiusM: min(0.006, max(0.0015, frustumDepthM * 0.009)),
            frustumStrokeRadiusM: min(
                0.006,
                max(0.0015, frustumDepthM * 0.011)
            )
        )
    }

    private static func boundingRadius(
        of positions: [SIMD3<Float>]
    ) -> Float {
        guard var minimum = positions.first else { return 0 }
        var maximum = minimum
        for position in positions.dropFirst() {
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }
        return simd_length(maximum - minimum) * 0.5
    }
}
