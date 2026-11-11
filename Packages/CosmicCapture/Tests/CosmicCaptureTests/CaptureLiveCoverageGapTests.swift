import Foundation
import simd
import Testing
@testable import CosmicCapture

@Suite("Live coverage gaps")
struct CaptureLiveCoverageGapTests {
    private func gap(
        id: Int = 0,
        _ category: CaptureStructuralCategory,
        center: SIMD3<Float> = SIMD3(0, 2.4, 0),
        areaM2: Float = 1.2
    ) -> CaptureCoverageGap {
        CaptureCoverageGap(
            id: id,
            category: category,
            center: center,
            radiusM: 0.8,
            areaM2: areaM2,
            label: CaptureCoverageGapAnalyzer.label(
                forRegion: CaptureCoverageGapAnalyzer.regionName(
                    for: category,
                    centerY: center.y,
                    sceneMinY: 0,
                    sceneMaxY: 2.6
                )
            )
        )
    }

    // MARK: - Throttle
    //
    // `shouldAnalyze` and `select` are `mutating`, and `#expect` captures its
    // operands immutably, so every call is bound to a `let` first. The
    // bindings run in the same order as the calls they replace, which is what
    // these sequential-state tests are actually asserting.

    @Test("No analysis before the scan has warmed up")
    func warmupGate() {
        var scheduler = CaptureLiveCoverageGapScheduler()
        let beforeWarmup = scheduler.shouldAnalyze(at: 100, scanningSeconds: 5)
        let justUnderWarmup = scheduler.shouldAnalyze(at: 110, scanningSeconds: 19.9)
        let atWarmup = scheduler.shouldAnalyze(at: 120, scanningSeconds: 20)

        #expect(!beforeWarmup)
        #expect(!justUnderWarmup)
        #expect(atWarmup)
    }

    @Test("Analysis runs immediately, then at a bounded cadence")
    func throttleCadence() {
        var scheduler = CaptureLiveCoverageGapScheduler()

        let first = scheduler.shouldAnalyze(at: 100, scanningSeconds: 30)
        let tooSoon = scheduler.shouldAnalyze(at: 105, scanningSeconds: 35)
        let justUnderInterval = scheduler.shouldAnalyze(at: 111.9, scanningSeconds: 42)
        let atInterval = scheduler.shouldAnalyze(at: 112, scanningSeconds: 42)
        let tooSoonAgain = scheduler.shouldAnalyze(at: 120, scanningSeconds: 50)
        let nextInterval = scheduler.shouldAnalyze(at: 124, scanningSeconds: 54)

        #expect(first)
        #expect(!tooSoon)
        #expect(!justUnderInterval)
        #expect(atInterval)
        #expect(!tooSoonAgain)
        #expect(nextInterval)
    }

    @Test("Reset clears the throttle and confirmation state")
    func resetClearsState() {
        var scheduler = CaptureLiveCoverageGapScheduler()
        _ = scheduler.shouldAnalyze(at: 100, scanningSeconds: 30)
        _ = scheduler.select(from: [gap(.ceiling)])
        _ = scheduler.select(from: [gap(.ceiling)])

        scheduler.reset()

        let analyzesAgain = scheduler.shouldAnalyze(at: 101, scanningSeconds: 30)
        // Confirmation starts over, so one pass is no longer enough.
        let firstAfterReset = scheduler.select(from: [gap(.ceiling)])

        #expect(analyzesAgain)
        #expect(firstAfterReset == nil)
    }

    // MARK: - Confirmation

    @Test("A region must persist across passes before it is coached")
    func requiresConfirmation() {
        var scheduler = CaptureLiveCoverageGapScheduler()

        let firstSighting = scheduler.select(from: [gap(.ceiling)])
        let confirmed = scheduler.select(from: [gap(.ceiling)])

        #expect(firstSighting == nil)
        #expect(confirmed?.category == .ceiling)
        #expect(confirmed?.label == "Possible gap in the ceiling")
    }

    @Test("A one-off region never reaches the pill")
    func transientRegionStaysSilent() {
        var scheduler = CaptureLiveCoverageGapScheduler()

        let firstSighting = scheduler.select(from: [gap(.ceiling)])
        // The user walked over and covered it before the next pass.
        let afterCovered = scheduler.select(from: [])
        // It reappears once: still only a first sighting.
        let reappeared = scheduler.select(from: [gap(.ceiling)])

        #expect(firstSighting == nil)
        #expect(afterCovered == nil)
        #expect(reappeared == nil)
    }

    @Test("A gap that jumps across the room restarts confirmation")
    func movedRegionRestartsConfirmation() {
        var scheduler = CaptureLiveCoverageGapScheduler()

        let firstWall = scheduler.select(from: [gap(.wall, center: SIMD3(0, 1.4, 0))])
        // Same category, but a different wall entirely.
        let movedWall = scheduler.select(from: [gap(.wall, center: SIMD3(5, 1.4, 0))])
        let movedWallConfirmed = scheduler.select(
            from: [gap(.wall, center: SIMD3(5, 1.4, 0))]
        )

        #expect(firstWall == nil)
        #expect(movedWall == nil)
        #expect(movedWallConfirmed != nil)
    }

    @Test("A drifting centroid still counts as the same region")
    func centroidDriftTolerated() {
        var scheduler = CaptureLiveCoverageGapScheduler()

        let firstSighting = scheduler.select(
            from: [gap(.ceiling, center: SIMD3(0, 2.4, 0))]
        )
        let confirmed = scheduler.select(
            from: [gap(.ceiling, center: SIMD3(0.4, 2.4, 0.3))]
        )

        #expect(firstSighting == nil)
        #expect(confirmed != nil)
    }

    // MARK: - Selection

    @Test("Only one gap is ever surfaced, even when two are ranked")
    func surfacesOneGap() {
        var scheduler = CaptureLiveCoverageGapScheduler()
        let ranked = [
            gap(id: 0, .ceiling, center: SIMD3(0, 2.4, 0)),
            gap(id: 1, .wall, center: SIMD3(2, 1.4, 0)),
        ]

        let firstPass = scheduler.select(from: ranked)
        let selected = scheduler.select(from: ranked)

        #expect(firstPass == nil)
        #expect(selected?.category == .ceiling)
    }

    @Test("Selection sticks to the region already on screen")
    func selectionIsSticky() {
        var scheduler = CaptureLiveCoverageGapScheduler()
        let ceiling = gap(id: 0, .ceiling, center: SIMD3(0, 2.4, 0))
        let wall = gap(id: 1, .wall, center: SIMD3(2, 1.4, 0))

        _ = scheduler.select(from: [ceiling, wall])
        let confirmed = scheduler.select(from: [ceiling, wall])
        // The wall now outranks the ceiling, but the ceiling is still a
        // confirmed gap, so the message must not flip.
        let afterReranking = scheduler.select(from: [wall, ceiling])
        // Once the ceiling is filled, the wall takes over.
        let afterCeilingFilled = scheduler.select(from: [wall])

        #expect(confirmed?.category == .ceiling)
        #expect(afterReranking?.category == .ceiling)
        #expect(afterCeilingFilled?.category == .wall)
    }

    @Test("An empty result clears the selection")
    func emptyResultClears() {
        var scheduler = CaptureLiveCoverageGapScheduler()
        _ = scheduler.select(from: [gap(.ceiling)])
        let confirmed = scheduler.select(from: [gap(.ceiling)])
        let cleared = scheduler.select(from: [])

        #expect(confirmed != nil)
        #expect(cleared == nil)
    }

    // MARK: - Voxel snapshot

    @Test("Snapshot reproduces exact-voxel coverage, with no dilation")
    func snapshotMatchesTracker() {
        let tracker = CaptureCoverageTracker()
        tracker.integrate(
            CaptureCoverageObservation(
                timestamp: 1,
                cameraPosition: SIMD3(0, 1.4, 1),
                points: [
                    CaptureCoveragePoint(position: SIMD3(0, 1, 0), confidence: 2),
                ]
            )
        )

        let covered = CaptureClassifiedFace(
            center: SIMD3(0, 1, 0),
            normal: SIMD3(0, 0, 1),
            areaM2: 0.2,
            category: .wall
        )
        // One voxel (7.5 cm) away: the tracker's neighbor slack would call
        // this covered, exact-voxel lookup must not.
        let neighbor = CaptureClassifiedFace(
            center: SIMD3(0.08, 1, 0),
            normal: SIMD3(0, 0, 1),
            areaM2: 0.2,
            category: .wall
        )
        let snapshot = CaptureCoverageVoxelSnapshot(
            tracker: tracker,
            faces: [covered, neighbor]
        )

        #expect(snapshot.isCovered(covered.center))
        #expect(!snapshot.isCovered(neighbor.center))
        #expect(tracker.hasCoverage(near: neighbor.center))
    }

    @Test("Snapshot and the review path agree on the same gaps")
    func snapshotAgreesWithReviewPath() {
        let tracker = CaptureCoverageTracker()
        var faces: [CaptureClassifiedFace] = []
        for xi in 0..<16 {
            for zi in 0..<16 {
                let center = SIMD3<Float>(Float(xi) * 0.25, 2.5, Float(zi) * 0.25)
                faces.append(
                    CaptureClassifiedFace(
                        center: center,
                        normal: SIMD3(0, -1, 0),
                        areaM2: 0.06,
                        category: .ceiling
                    )
                )
                // Leave a surrounded hole inside the scanned ceiling.
                guard !(6...9).contains(xi) || !(6...9).contains(zi) else { continue }
                tracker.integrate(
                    CaptureCoverageObservation(
                        timestamp: 1,
                        cameraPosition: SIMD3(center.x, 1.4, center.z),
                        points: [
                            CaptureCoveragePoint(position: center, confidence: 2),
                        ]
                    )
                )
            }
        }

        let snapshot = CaptureCoverageVoxelSnapshot(tracker: tracker, faces: faces)
        let cameras = (0..<16).map {
            SIMD3<Float>(Float($0) * 0.25, 1.4, 2)
        }
        let viaTracker = CaptureCoverageGapAnalyzer.rankedGaps(
            faces: faces,
            isCovered: { tracker.voxel(at: $0) != nil },
            cameraPositions: cameras
        )
        let viaSnapshot = CaptureCoverageGapAnalyzer.rankedGaps(
            faces: faces,
            isCovered: snapshot.isCovered(_:),
            cameraPositions: cameras
        )

        #expect(!viaTracker.isEmpty)
        #expect(viaTracker == viaSnapshot)
    }

    // MARK: - Ambient readout

    @Test("Spoken readout replaces glyphs with words and never a number")
    func spokenReadoutIsSpeakable() {
        let spoken = CaptureStructuralSummary.spokenReadout(
            "Walls 3/4 · Floor ✓ · Ceiling —"
        )
        #expect(spoken == "Walls 3 of 4, Floor covered, Ceiling not covered yet")
        #expect(!spoken.contains("%"))

        let partial = CaptureStructuralSummary.spokenReadout(
            "Walls — · Floor ◐ · Ceiling ✓"
        )
        #expect(
            partial == "Walls not covered yet, Floor partly covered, Ceiling covered"
        )
    }

    @Test("A never-observed ceiling still reads as not covered yet")
    func neverObservedCeilingReadsHonestly() {
        // The mesh has walls and a floor but no ceiling face at all — the case
        // the gap analyzer is structurally blind to, because ARKit only meshes
        // what the camera pointed at.
        let tracker = CaptureCoverageTracker()
        var faces: [CaptureClassifiedFace] = []
        for xi in 0..<12 {
            let center = SIMD3<Float>(Float(xi) * 0.25, 1.2, 0)
            faces.append(
                CaptureClassifiedFace(
                    center: center,
                    normal: SIMD3(0, 0, 1),
                    areaM2: 0.3,
                    category: .wall
                )
            )
            tracker.integrate(
                CaptureCoverageObservation(
                    timestamp: 1,
                    cameraPosition: SIMD3(center.x, 1.4, 1),
                    points: [CaptureCoveragePoint(position: center, confidence: 2)]
                )
            )
        }
        tracker.updateStructuralSummary(faces: faces)

        let readout = tracker.structuralSummary.readoutLine
        #expect(readout.contains("Ceiling —"))
        // ...and no nudge fires, because zero ceiling area is not evidence of
        // a ceiling. The readout is what carries this case.
        #expect(!tracker.structuralSummary.nudgeCandidates().contains(.ceiling))
    }
}
