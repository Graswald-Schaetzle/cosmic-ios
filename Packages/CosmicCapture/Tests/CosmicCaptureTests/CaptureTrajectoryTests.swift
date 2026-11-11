import Foundation
import simd
import Testing
@testable import CosmicCapture

@Suite("Capture trajectory")
struct CaptureTrajectoryTests {
    @Test("Recovers ARKit world-from-camera from contract poses")
    func recoversARKitConvention() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = CameraGeometry.makeTransform(
            rotation: CameraGeometry.makeRotation(
                xDegrees: 12,
                yDegrees: -23,
                zDegrees: 7
            ),
            translation: SIMD3(1.25, -0.4, 2.5)
        )
        let contractPose = CameraGeometry.opencvCameraFromWorld(
            arkitWorldFromCamera: expected
        )
        let trajectoryURL = directory.appendingPathComponent("trajectory.json")
        let data = try JSONEncoder().encode([contractPose.rowMajorArray])
        try data.write(to: trajectoryURL)

        let loaded = try CaptureTrajectoryStore.load(
            trajectoryURL: trajectoryURL,
            frameRecordsDirectoryURL: directory.appendingPathComponent("missing")
        )

        #expect(loaded.arkitWorldFromCamera.count == 1)
        expectApproximatelyEqual(
            loaded.arkitWorldFromCamera[0],
            expected
        )
    }

    @Test("Falls back to local ARKit frame records")
    func fallsBackToFrameRecords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordsDirectory = directory.appendingPathComponent("records")
        try FileManager.default.createDirectory(
            at: recordsDirectory,
            withIntermediateDirectories: true
        )
        let expected = CameraGeometry.makeTransform(
            rotation: matrix_identity_float3x3,
            translation: SIMD3(0.3, 0.2, -0.7)
        )
        let record = CaptureFrameRecord(
            frameIndex: 1,
            arkitWorldFromCamera: expected.rowMajorArray,
            fxPx: 1_000,
            fyPx: 1_000,
            cxPx: 960,
            cyPx: 720,
            widthPx: 1_920,
            heightPx: 1_440,
            sampleReason: "initial"
        )
        let recordURL = recordsDirectory.appendingPathComponent(
            "Frame_000001.json"
        )
        try JSONEncoder().encode(record).write(to: recordURL)

        let loaded = try CaptureTrajectoryStore.load(
            trajectoryURL: directory.appendingPathComponent("missing.json"),
            frameRecordsDirectoryURL: recordsDirectory
        )

        #expect(loaded.arkitWorldFromCamera.count == 1)
        expectApproximatelyEqual(
            loaded.arkitWorldFromCamera[0],
            expected
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func expectApproximatelyEqual(
        _ actual: simd_float4x4,
        _ expected: simd_float4x4,
        tolerance: Float = 0.0001
    ) {
        for row in 0..<4 {
            for column in 0..<4 {
                #expect(
                    abs(actual[column][row] - expected[column][row]) < tolerance
                )
            }
        }
    }
}
