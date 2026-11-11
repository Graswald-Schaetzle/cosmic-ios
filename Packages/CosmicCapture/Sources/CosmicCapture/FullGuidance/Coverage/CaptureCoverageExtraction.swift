import ARKit
import CoreVideo
import Foundation
import simd

/// Unprojects a sparse grid of LiDAR depth samples into world space for
/// coverage integration. The math core is pure for testability; the pixel
/// buffer walk stays cheap (a few hundred samples per accepted keyframe).
enum CaptureDepthUnprojector {
    /// ARKit camera space is +x right, +y up, -z forward with the image origin
    /// top-left, so unprojection negates y and z.
    static func unprojectToWorld(
        u: Float,
        v: Float,
        depthM: Float,
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float,
        worldFromCamera: simd_float4x4
    ) -> SIMD3<Float> {
        let local = SIMD4<Float>(
            (u - cx) * depthM / fx,
            -(v - cy) * depthM / fy,
            -depthM,
            1
        )
        let world = worldFromCamera * local
        return SIMD3(world.x, world.y, world.z)
    }

    /// Builds a coverage observation from an ARKit depth frame. Returns nil
    /// when the depth format is unexpected or no sample passes the filters.
    ///
    /// - Parameters:
    ///   - intrinsics: Camera intrinsics for `imageWidth × imageHeight`; they
    ///     are rescaled to the depth map's resolution internally.
    ///   - maxDepthM: LiDAR readings beyond this are too noisy to claim as
    ///     coverage.
    static func observation(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        worldFromCamera: simd_float4x4,
        intrinsics: simd_float3x3,
        imageWidth: Int,
        imageHeight: Int,
        timestamp: TimeInterval,
        gridWidth: Int = 32,
        gridHeight: Int = 24,
        maxDepthM: Float = 8
    ) -> CaptureCoverageObservation? {
        guard CVPixelBufferGetPixelFormatType(depthMap)
            == kCVPixelFormatType_DepthFloat32
        else {
            return nil
        }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        guard depthWidth > 0, depthHeight > 0 else { return nil }

        var confidenceBase: UnsafeRawPointer?
        var confidenceStride = 0
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap)
                .map(UnsafeRawPointer.init)
            confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        let scaled = CameraGeometry.scaleIntrinsics(
            fx: intrinsics.columns.0.x,
            fy: intrinsics.columns.1.y,
            cx: intrinsics.columns.2.x,
            cy: intrinsics.columns.2.y,
            fromWidth: imageWidth,
            fromHeight: imageHeight,
            toWidth: depthWidth,
            toHeight: depthHeight
        )

        let cameraPosition = SIMD3<Float>(
            worldFromCamera.columns.3.x,
            worldFromCamera.columns.3.y,
            worldFromCamera.columns.3.z
        )

        var points: [CaptureCoveragePoint] = []
        points.reserveCapacity(gridWidth * gridHeight)

        for gridY in 0..<gridHeight {
            let y = gridY * depthHeight / gridHeight
            let depthRow = depthBase.advanced(by: y * depthStride)
                .assumingMemoryBound(to: Float32.self)
            for gridX in 0..<gridWidth {
                let x = gridX * depthWidth / gridWidth
                let depth = depthRow[x]
                guard depth.isFinite, depth > 0.05, depth <= maxDepthM else {
                    continue
                }
                var confidence: UInt8 = 2
                if let confidenceBase {
                    confidence = confidenceBase
                        .advanced(by: y * confidenceStride + x)
                        .assumingMemoryBound(to: UInt8.self)
                        .pointee
                }
                let world = unprojectToWorld(
                    u: Float(x),
                    v: Float(y),
                    depthM: depth,
                    fx: scaled.fx,
                    fy: scaled.fy,
                    cx: scaled.cx,
                    cy: scaled.cy,
                    worldFromCamera: worldFromCamera
                )
                points.append(
                    CaptureCoveragePoint(position: world, confidence: confidence)
                )
            }
        }

        guard !points.isEmpty else { return nil }
        return CaptureCoverageObservation(
            timestamp: timestamp,
            cameraPosition: cameraPosition,
            points: points
        )
    }
}

/// Extracts classified faces from LiDAR mesh anchors for structural
/// aggregation. Subsampled — the readout needs area ratios, not every face.
enum CaptureMeshClassificationExtractor {
    static func classifiedFaces(
        from anchors: [ARMeshAnchor],
        faceStride: Int = 4
    ) -> [CaptureClassifiedFace] {
        var result: [CaptureClassifiedFace] = []
        for anchor in anchors {
            appendFaces(
                from: anchor,
                faceStride: max(1, faceStride),
                into: &result
            )
        }
        return result
    }

    private static func appendFaces(
        from anchor: ARMeshAnchor,
        faceStride: Int,
        into result: inout [CaptureClassifiedFace]
    ) {
        let geometry = anchor.geometry
        guard let classification = geometry.classification else { return }
        let faces = geometry.faces
        guard faces.indexCountPerPrimitive == 3 else { return }

        let vertices = geometry.vertices
        let vertexPointer = vertices.buffer.contents()
        let facePointer = faces.buffer.contents()
        let classPointer = classification.buffer.contents()
        let transform = anchor.transform

        var faceIndex = 0
        while faceIndex < faces.count {
            defer { faceIndex += faceStride }

            let classValue = classPointer
                .advanced(by: classification.offset + classification.stride * faceIndex)
                .assumingMemoryBound(to: UInt8.self)
                .pointee
            guard let category = structuralCategory(
                ARMeshClassification(rawValue: Int(classValue)) ?? .none
            ) else {
                continue
            }

            var corners = [SIMD3<Float>](repeating: .zero, count: 3)
            for corner in 0..<3 {
                let indexOffset = (faceIndex * 3 + corner) * faces.bytesPerIndex
                let vertexIndex: Int
                if faces.bytesPerIndex == 4 {
                    vertexIndex = Int(
                        facePointer.advanced(by: indexOffset)
                            .assumingMemoryBound(to: UInt32.self)
                            .pointee
                    )
                } else {
                    vertexIndex = Int(
                        facePointer.advanced(by: indexOffset)
                            .assumingMemoryBound(to: UInt16.self)
                            .pointee
                    )
                }
                // Packed float3: load components individually — a SIMD3 load
                // would read 16 bytes from a 12-byte-stride buffer.
                let pointer = vertexPointer
                    .advanced(by: vertices.offset + vertices.stride * vertexIndex)
                let local = SIMD3<Float>(
                    pointer.load(as: Float.self),
                    pointer.load(fromByteOffset: 4, as: Float.self),
                    pointer.load(fromByteOffset: 8, as: Float.self)
                )
                let world = transform * SIMD4(local.x, local.y, local.z, 1)
                corners[corner] = SIMD3(world.x, world.y, world.z)
            }

            let edge1 = corners[1] - corners[0]
            let edge2 = corners[2] - corners[0]
            let cross = simd_cross(edge1, edge2)
            let crossLength = simd_length(cross)
            guard crossLength > 1e-9 else { continue }

            result.append(
                CaptureClassifiedFace(
                    center: (corners[0] + corners[1] + corners[2]) / 3,
                    normal: cross / crossLength,
                    // Compensate for subsampling so area ratios stay unbiased.
                    areaM2: 0.5 * crossLength * Float(faceStride),
                    category: category
                )
            )
        }
    }

    private static func structuralCategory(
        _ classification: ARMeshClassification
    ) -> CaptureStructuralCategory? {
        switch classification {
        case .floor: return .floor
        case .ceiling: return .ceiling
        case .wall: return .wall
        // Doors, windows, seats, tables and unclassified faces are not
        // structural shell — and intentional openings must never be reported
        // as missing coverage.
        default: return nil
        }
    }
}
