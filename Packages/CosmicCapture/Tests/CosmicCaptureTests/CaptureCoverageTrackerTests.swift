import CoreVideo
import Foundation
import simd
import Testing
@testable import CosmicCapture

@Suite("CaptureCoverageTracker")
struct CaptureCoverageTrackerTests {
    private func observation(
        points: [SIMD3<Float>],
        camera: SIMD3<Float>,
        confidence: UInt8 = 2,
        timestamp: TimeInterval = 0
    ) -> CaptureCoverageObservation {
        CaptureCoverageObservation(
            timestamp: timestamp,
            cameraPosition: camera,
            points: points.map {
                CaptureCoveragePoint(position: $0, confidence: confidence)
            }
        )
    }

    @Test("Points inside the same voxel quantize to one entry")
    func quantization() {
        let tracker = CaptureCoverageTracker(voxelSizeM: 0.1)
        tracker.integrate(
            observation(
                points: [SIMD3(0.01, 0.01, 0.01), SIMD3(0.09, 0.05, 0.02)],
                camera: SIMD3(1, 0, 0)
            )
        )
        #expect(tracker.voxelCount == 1)
        #expect(tracker.voxel(at: SIMD3(0.05, 0.05, 0.05))?.observationCount == 2)
    }

    @Test("Low-confidence depth points are ignored entirely")
    func confidenceFilter() {
        let tracker = CaptureCoverageTracker()
        tracker.integrate(
            observation(points: [SIMD3(1, 1, 1)], camera: .zero, confidence: 0)
        )
        #expect(tracker.voxelCount == 0)

        tracker.integrate(
            observation(points: [SIMD3(1, 1, 1)], camera: .zero, confidence: 1)
        )
        #expect(tracker.voxelCount == 1)
    }

    @Test("A single viewpoint stays seen, never solid")
    func singleViewpointStaysSeen() {
        let tracker = CaptureCoverageTracker()
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(2, 0, 0))
        )
        #expect(tracker.voxel(at: .zero)?.state == .seen)
    }

    @Test("Stationary repeats never add angular diversity")
    func stationaryRepeats() {
        let tracker = CaptureCoverageTracker()
        for i in 0..<50 {
            tracker.integrate(
                observation(
                    points: [SIMD3(0, 0, 0)],
                    camera: SIMD3(2, 0, 0),
                    timestamp: TimeInterval(i)
                )
            )
        }
        let voxel = tracker.voxel(at: .zero)
        #expect(voxel?.state == .seen)
        #expect(voxel?.observationCount == 50)
        #expect(tracker.solidFraction == 0)
    }

    @Test("A second, angularly distinct view solidifies the voxel")
    func distinctViewSolidifies() {
        let tracker = CaptureCoverageTracker()
        // Opposite sides of the surface point: azimuth sectors far apart.
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(2, 0, 0))
        )
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(-2, 0, 0))
        )
        #expect(tracker.voxel(at: .zero)?.state == .solid)
        #expect(tracker.solidFraction == 1)
    }

    @Test("Adjacent azimuth sectors are not distinct enough to solidify")
    func adjacentSectorsStaySeen() {
        let tracker = CaptureCoverageTracker()
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(2, 0, 0))
        )
        // 45° away: neighboring sector, below the ≥2-sector requirement.
        tracker.integrate(
            observation(
                points: [SIMD3(0, 0, 0)],
                camera: SIMD3(1.414, 0, 1.414)
            )
        )
        #expect(tracker.voxel(at: .zero)?.state == .seen)
    }

    @Test("Views from both elevation rows solidify")
    func elevationDiversitySolidifies() {
        let tracker = CaptureCoverageTracker()
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(2, 0, 0))
        )
        // Mostly from above: high elevation row.
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(0.5, 2, 0))
        )
        #expect(tracker.voxel(at: .zero)?.state == .solid)
    }

    @Test("Voxel count respects the hard memory bound")
    func memoryBound() {
        let tracker = CaptureCoverageTracker(voxelSizeM: 0.1, maxVoxelCount: 2)
        tracker.integrate(
            observation(
                points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)],
                camera: SIMD3(0, 2, 0)
            )
        )
        #expect(tracker.voxelCount == 2)

        // Existing voxels still update at the bound.
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(0, 2, 0))
        )
        #expect(tracker.voxel(at: .zero)?.observationCount == 2)
    }

    @Test("Paint tolerates one-voxel mesh refinement without changing truth")
    func toleranceAwarePaintLookup() {
        let tracker = CaptureCoverageTracker(voxelSizeM: 0.1)
        tracker.integrate(
            observation(
                points: [SIMD3(0.09, 0, 0)],
                camera: SIMD3(1, 0, 0)
            )
        )
        let refinedPosition = SIMD3<Float>(0.11, 0, 0)
        #expect(tracker.voxel(at: refinedPosition) == nil)
        #expect(tracker.voxelForPaint(near: refinedPosition)?.state == .seen)
        #expect(tracker.voxelForPaint(near: SIMD3(0.21, 0, 0)) == nil)
    }

    @Test("Paint lookup benchmark uses one hash probe per vertex")
    func paintLookupProbeBenchmark() {
        let tracker = CaptureCoverageTracker(voxelSizeM: 0.1)
        let points = (0..<40).flatMap { x in
            (0..<40).map { z in SIMD3(Float(x) * 0.1, 0, Float(z) * 0.1) }
        }
        tracker.integrate(observation(points: points, camera: SIMD3(2, 1, 2)))
        var dictionaryProbes = 0
        for index in 0..<10_000 {
            let coordinate = Float(index % 40) * 0.1
            dictionaryProbes += tracker.paintLookup(at:
                SIMD3(coordinate, 0.01, coordinate)).dictionaryProbeCount
        }
        #expect(dictionaryProbes == 10_000)
    }

    @Test("Thermal pressure retains evidence and only slows rendering")
    func thermalPressurePolicy() {
        let tracker = CaptureCoverageTracker()
        for (index, thermalState) in [ProcessInfo.ThermalState.serious, .critical].enumerated() {
            CaptureCoverageCommitPolicy.integrate(
                observation(
                    points: [.zero],
                    camera: SIMD3(1, 0, 0),
                    timestamp: TimeInterval(index)
                ),
                into: tracker,
                thermalState: thermalState
            )
        }
        #expect(tracker.voxel(at: .zero)?.observationCount == 2)
        #expect(
            CaptureOverlayRenderCadence.minimumInterval(for: .critical)
                > CaptureOverlayRenderCadence.minimumInterval(for: .serious)
        )
    }

    @Test("Serialization roundtrips voxel states")
    func serializationRoundtrip() {
        let tracker = CaptureCoverageTracker(voxelSizeM: 0.075)
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(2, 0, 0))
        )
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(-2, 0, 0))
        )
        tracker.integrate(
            observation(points: [SIMD3(1, 1, 1)], camera: SIMD3(2, 0, 0), confidence: 1)
        )

        let restored = CaptureCoverageTracker.deserialize(tracker.serialized())
        #expect(restored != nil)
        #expect(restored?.voxelSizeM == 0.075)
        #expect(restored?.voxelCount == 2)
        #expect(restored?.voxel(at: .zero)?.state == .solid)
        #expect(restored?.voxel(at: SIMD3(1, 1, 1))?.state == .seen)
        #expect(restored?.voxel(at: SIMD3(1, 1, 1))?.maxConfidence == 1)
    }

    @Test("Corrupt serialized data is rejected")
    func corruptDataRejected() {
        #expect(CaptureCoverageTracker.deserialize(Data()) == nil)
        #expect(CaptureCoverageTracker.deserialize(Data("nope".utf8)) == nil)

        var truncated = CaptureCoverageTracker().serialized()
        var count = UInt32(9).littleEndian
        withUnsafeBytes(of: &count) { bytes in
            truncated.replaceSubrange(12..<16, with: bytes)
        }
        #expect(CaptureCoverageTracker.deserialize(truncated) == nil)
    }

    // MARK: - Structural summary

    private func face(
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        area: Float,
        category: CaptureStructuralCategory
    ) -> CaptureClassifiedFace {
        CaptureClassifiedFace(
            center: center,
            normal: normal,
            areaM2: area,
            category: category
        )
    }

    @Test("Walls cluster by normal azimuth into distinct instances")
    func wallClustering() {
        let tracker = CaptureCoverageTracker()
        // Cover the +x wall only.
        tracker.integrate(
            observation(points: [SIMD3(2, 1, 0)], camera: SIMD3(0, 1, 0))
        )

        tracker.updateStructuralSummary(faces: [
            face(center: SIMD3(2, 1, 0), normal: SIMD3(-1, 0, 0), area: 2, category: .wall),
            face(center: SIMD3(-2, 1, 0), normal: SIMD3(1, 0, 0), area: 2, category: .wall),
        ])

        let summary = tracker.structuralSummary
        #expect(summary.wallsTotal == 2)
        #expect(summary.wallsCovered == 1)
    }

    @Test("Tiny wall fragments are filtered as noise")
    func smallWallsFiltered() {
        let tracker = CaptureCoverageTracker()
        tracker.updateStructuralSummary(faces: [
            face(center: SIMD3(2, 1, 0), normal: SIMD3(-1, 0, 0), area: 0.3, category: .wall)
        ])
        #expect(tracker.structuralSummary.wallsTotal == 0)
    }

    @Test("Floor and ceiling coverage aggregates by area")
    func floorCeilingAggregation() {
        let tracker = CaptureCoverageTracker()
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(0, 2, 0))
        )

        tracker.updateStructuralSummary(faces: [
            face(center: SIMD3(0, 0, 0), normal: SIMD3(0, 1, 0), area: 3, category: .floor),
            face(center: SIMD3(5, 0, 5), normal: SIMD3(0, 1, 0), area: 1, category: .floor),
            face(center: SIMD3(0, 2.5, 0), normal: SIMD3(0, -1, 0), area: 4, category: .ceiling),
        ])

        let summary = tracker.structuralSummary
        #expect(summary.floor.totalAreaM2 == 4)
        #expect(summary.floor.coveredAreaM2 == 3)
        #expect(summary.ceiling.coveredAreaM2 == 0)
    }

    @Test("Readout line reflects category coverage")
    func readoutLine() {
        let tracker = CaptureCoverageTracker()
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(0, 2, 0))
        )
        tracker.updateStructuralSummary(faces: [
            face(center: SIMD3(0, 0, 0), normal: SIMD3(0, 1, 0), area: 3, category: .floor),
            face(center: SIMD3(0, 2.5, 0), normal: SIMD3(0, -1, 0), area: 4, category: .ceiling),
            face(center: SIMD3(2, 1, 0), normal: SIMD3(-1, 0, 0), area: 2, category: .wall),
        ])
        #expect(tracker.structuralSummary.readoutLine == "Walls 0/1 · Floor ✓ · Ceiling —")
    }

    @Test("Nudge candidates require meshed area with zero coverage")
    func nudgeCandidates() {
        let tracker = CaptureCoverageTracker()
        tracker.integrate(
            observation(points: [SIMD3(0, 0, 0)], camera: SIMD3(0, 2, 0))
        )
        tracker.updateStructuralSummary(faces: [
            face(center: SIMD3(0, 0, 0), normal: SIMD3(0, 1, 0), area: 3, category: .floor),
            face(center: SIMD3(0, 2.5, 0), normal: SIMD3(0, -1, 0), area: 4, category: .ceiling),
            // Below the minimum area: too little wall meshed to nudge honestly.
            face(center: SIMD3(2, 1, 0), normal: SIMD3(-1, 0, 0), area: 0.5, category: .wall),
        ])

        let candidates = tracker.structuralSummary.nudgeCandidates()
        #expect(candidates == [.ceiling])
    }
}

@Suite("CaptureDepthUnprojector")
struct CaptureDepthUnprojectorTests {
    @Test("Center pixel unprojects straight ahead")
    func centerPixel() {
        let world = CaptureDepthUnprojector.unprojectToWorld(
            u: 128,
            v: 96,
            depthM: 2,
            fx: 200,
            fy: 200,
            cx: 128,
            cy: 96,
            worldFromCamera: matrix_identity_float4x4
        )
        #expect(simd_distance(world, SIMD3(0, 0, -2)) < 1e-5)
    }

    @Test("Image axes map to camera axes with y and z negated")
    func axisConvention() {
        // Right of center → +x; below center (larger v) → -y.
        let world = CaptureDepthUnprojector.unprojectToWorld(
            u: 228,
            v: 196,
            depthM: 2,
            fx: 200,
            fy: 200,
            cx: 128,
            cy: 96,
            worldFromCamera: matrix_identity_float4x4
        )
        #expect(abs(world.x - 1) < 1e-5)
        #expect(abs(world.y - -1) < 1e-5)
        #expect(abs(world.z - -2) < 1e-5)
    }

    @Test("Camera transform carries points into world space")
    func cameraTransformApplied() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(10, 5, -3, 1)
        let world = CaptureDepthUnprojector.unprojectToWorld(
            u: 128,
            v: 96,
            depthM: 1,
            fx: 200,
            fy: 200,
            cx: 128,
            cy: 96,
            worldFromCamera: transform
        )
        #expect(simd_distance(world, SIMD3(10, 5, -4)) < 1e-5)
    }

    @Test("Observation samples a synthetic depth buffer")
    func syntheticDepthBuffer() throws {
        let width = 64
        let height = 48
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_DepthFloat32,
            nil,
            &pixelBuffer
        )
        let depthMap = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(depthMap, [])
        let base = try #require(CVPixelBufferGetBaseAddress(depthMap))
        let stride = CVPixelBufferGetBytesPerRow(depthMap)
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
                .assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                row[x] = 2
            }
        }
        CVPixelBufferUnlockBaseAddress(depthMap, [])

        var intrinsics = matrix_identity_float3x3
        intrinsics.columns.0.x = 1000
        intrinsics.columns.1.y = 1000
        intrinsics.columns.2.x = 960
        intrinsics.columns.2.y = 720

        let observation = CaptureDepthUnprojector.observation(
            depthMap: depthMap,
            confidenceMap: nil,
            worldFromCamera: matrix_identity_float4x4,
            intrinsics: intrinsics,
            imageWidth: 1920,
            imageHeight: 1440,
            timestamp: 1,
            gridWidth: 8,
            gridHeight: 6
        )

        let result = try #require(observation)
        #expect(result.points.count == 48)
        #expect(result.cameraPosition == .zero)
        // Constant depth 2 m: every point sits on the z = -2 plane.
        for point in result.points {
            #expect(abs(point.position.z + 2) < 1e-4)
            // No confidence map: treated as high confidence.
            #expect(point.confidence == 2)
        }
    }
}

@Suite("Coverage paint policy")
struct CoveragePaintPolicyTests {
    private func voxel(
        state solid: Bool,
        confidence: UInt8 = 2,
        lastObservedAt: TimeInterval = -100
    ) -> CaptureCoverageTracker.Voxel {
        CaptureCoverageTracker.Voxel(
            observationCount: 1,
            // Sectors 0 and 4 are opposite: solid. Sector 0 alone: seen.
            viewDirectionBits: solid ? 0b10001 : 0b1,
            maxConfidence: confidence,
            lastObservedAt: lastObservedAt
        )
    }

    @Test("Unscanned is fully transparent")
    func unscannedTransparent() {
        let color = CaptureMeshOverlay.paintColor(voxel: nil, mode: .camera, now: 10)
        #expect(color.w == 0)
    }

    @Test("Solid renders firmer than seen; model mode firmer than camera")
    func opacityLadder() {
        let seen = CaptureMeshOverlay.paintColor(
            voxel: voxel(state: false),
            mode: .camera,
            now: 10
        )
        let solid = CaptureMeshOverlay.paintColor(
            voxel: voxel(state: true),
            mode: .camera,
            now: 10
        )
        let solidModel = CaptureMeshOverlay.paintColor(
            voxel: voxel(state: true),
            mode: .model,
            now: 10
        )
        #expect(seen.w > 0)
        #expect(solid.w > seen.w)
        #expect(solidModel.w > solid.w)
    }

    @Test("A just-committed observation pulses brighter, then settles")
    func commitPulse() {
        let pulsing = CaptureMeshOverlay.paintColor(
            voxel: voxel(state: false, lastObservedAt: 10),
            mode: .camera,
            now: 10.05
        )
        let settled = CaptureMeshOverlay.paintColor(
            voxel: voxel(state: false, lastObservedAt: 10),
            mode: .camera,
            now: 12
        )
        #expect(pulsing.w > settled.w)
        // Pulse brightens toward white.
        #expect(pulsing.x > settled.x)
    }

    @Test("Low-confidence-only coverage is visually distinct from good coverage")
    func lowConfidenceDistinct() {
        let good = CaptureMeshOverlay.paintColor(
            voxel: voxel(state: false, confidence: 2),
            mode: .camera,
            now: 10
        )
        let weak = CaptureMeshOverlay.paintColor(
            voxel: voxel(state: false, confidence: 1),
            mode: .camera,
            now: 10
        )
        #expect(abs(good.x - weak.x) > 0.2)
    }

    @Test("Paint depth-tests against an invisible depth prepass")
    func depthPolicy() {
        let paint = CaptureMeshOverlay.material(for: .paint)
        let depth = CaptureMeshOverlay.depthPrepassMaterial()
        #expect(paint.readsFromDepthBuffer && !paint.writesToDepthBuffer)
        #expect(paint.shaderModifiers?[.geometry] != nil)
        #expect(depth.readsFromDepthBuffer && depth.writesToDepthBuffer)
        #expect(depth.colorBufferWriteMask.rawValue == 0)
    }

    @Test("Camera paint stays in the current height band")
    func currentFloorVisibility() {
        let currentFloor = CaptureMeshOverlay.PaintWorldBounds(
            minimum: SIMD3(-1, -1.6, -1),
            maximum: SIMD3(1, 1.5, 1)
        )
        let otherFloor = CaptureMeshOverlay.PaintWorldBounds(
            minimum: SIMD3(-1, 2.7, -1),
            maximum: SIMD3(1, 3.8, 1)
        )
        #expect(CaptureMeshOverlay.shouldShowPaint(
            bounds: currentFloor, cameraPosition: .zero, mode: .camera))
        #expect(!CaptureMeshOverlay.shouldShowPaint(
            bounds: otherFloor, cameraPosition: .zero, mode: .camera))
        #expect(CaptureMeshOverlay.shouldShowPaint(
            bounds: otherFloor, cameraPosition: .zero, mode: .model))
    }
}

@Suite("isSolid bit rotation")
struct CaptureCoverageIsSolidTests {
    /// The pre-optimization sector-list implementation, kept as the reference
    /// for the allocation-free bit-rotation version that replaced it.
    private func referenceIsSolid(_ viewDirectionBits: UInt16) -> Bool {
        let low = viewDirectionBits & 0xFF
        let high = (viewDirectionBits >> 8) & 0xFF
        if low != 0, high != 0 { return true }

        let azimuthBits = low | high
        var sectors: [Int] = []
        for sector in 0..<8 where azimuthBits & (1 << sector) != 0 {
            sectors.append(sector)
        }
        guard sectors.count >= 2 else { return false }
        for i in 0..<sectors.count {
            for j in (i + 1)..<sectors.count {
                let distance = abs(sectors[i] - sectors[j])
                if min(distance, 8 - distance) >= 2 { return true }
            }
        }
        return false
    }

    @Test("Matches the sector-list reference for every possible mask")
    func exhaustiveEquivalence() {
        var mismatches: [UInt16] = []
        for bits in UInt16.min...UInt16.max
        where CaptureCoverageTracker.isSolid(viewDirectionBits: bits)
            != referenceIsSolid(bits)
        {
            mismatches.append(bits)
        }
        #expect(mismatches.isEmpty, "Mismatched masks: \(mismatches.prefix(20))")
    }
}
