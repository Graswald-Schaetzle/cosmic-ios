import Foundation
import ImageIO
import Testing
import simd
@testable import CosmicCapture

@Suite("LiDAR sidecar")
struct CaptureLidarSidecarTests {
    private static let triangleMesh = CaptureLidarMesh(
        groups: [
            .init(
                name: "floor",
                positions: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(0, 0, -3)],
                indices: [0, 1, 2]
            ),
            .init(
                name: "wall",
                positions: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 2.5, 0), SIMD3(0, 2.5, 0)],
                indices: [0, 1, 2, 0, 2, 3]
            ),
        ],
        anchorCount: 1,
        hasClassification: true
    )

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<offset + 4).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    @Test("GLB has a valid header, aligned chunks and one mesh per group")
    func glbStructure() throws {
        let glb = try CaptureLidarMeshGLBEncoder.encode(Self.triangleMesh)

        #expect(uint32(glb, at: 0) == 0x4654_6C67)
        #expect(uint32(glb, at: 4) == 2)
        #expect(Int(uint32(glb, at: 8)) == glb.count)

        let jsonLength = Int(uint32(glb, at: 12))
        #expect(uint32(glb, at: 16) == 0x4E4F_534A)
        #expect(jsonLength % 4 == 0)
        let json = try #require(
            JSONSerialization.jsonObject(with: glb.subdata(in: 20..<20 + jsonLength))
                as? [String: Any]
        )

        let binHeader = 20 + jsonLength
        let binLength = Int(uint32(glb, at: binHeader))
        #expect(uint32(glb, at: binHeader + 4) == 0x004E_4942)
        #expect(binLength % 4 == 0)
        #expect(binHeader + 8 + binLength == glb.count)

        let meshes = try #require(json["meshes"] as? [[String: Any]])
        #expect(meshes.compactMap { $0["name"] as? String } == ["floor", "wall"])
        let accessors = try #require(json["accessors"] as? [[String: Any]])
        #expect(accessors.map { $0["count"] as? Int } == [3, 3, 4, 6])
        let buffers = try #require(json["buffers"] as? [[String: Any]])
        // 7 vertices * 12 bytes + 9 indices * 4 bytes.
        #expect(buffers.first?["byteLength"] as? Int == 7 * 12 + 9 * 4)

        // The wall's positions round-trip, including its bounds.
        let views = try #require(json["bufferViews"] as? [[String: Any]])
        let wallOffset = try #require(views[2]["byteOffset"] as? Int)
        let bin = glb.subdata(in: binHeader + 8..<glb.count)
        let third: [Float] = (0..<3).map { component in
            bin.subdata(in: wallOffset + 24 + component * 4..<wallOffset + 28 + component * 4)
                .withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        }
        #expect(third == [2, 2.5, 0])
        #expect(accessors[2]["max"] as? [Double] == [2, 2.5, 0])
    }

    @Test("An empty mesh is rejected")
    func emptyMesh() {
        let mesh = CaptureLidarMesh(groups: [], anchorCount: 0, hasClassification: false)
        #expect(throws: CaptureLidarMeshGLBEncoder.EncodingError.self) {
            try CaptureLidarMeshGLBEncoder.encode(mesh)
        }
    }

    @Test("Depth converts to millimetres and marks invalid values as zero")
    func depthMillimeters() {
        let values = CaptureDepthEncoder.millimeters(
            fromMeters: [0, -1, .nan, .infinity, 0.0004, 1.2345, 70]
        )
        #expect(values == [0, 0, 0, 0, 0, 1235, 65535])
    }

    @Test("Depth PNG is 16-bit grayscale and keeps its values")
    func depthPNGRoundTrip() throws {
        let millimeters: [UInt16] = [0, 1, 255, 256, 1234, 65535]
        let png = try #require(
            CaptureDepthEncoder.depthPNG(width: 3, height: 2, millimeters: millimeters)
        )
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 3)
        #expect(image.height == 2)
        #expect(image.bitsPerComponent == 16)
        #expect(image.bitsPerPixel == 16)

        let pixels = try #require(image.dataProvider?.data as Data?)
        let isLittleEndian = image.bitmapInfo.contains(.byteOrder16Little)
        var decoded: [UInt16] = []
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * image.bytesPerRow + column * 2
                let first = UInt16(pixels[offset])
                let second = UInt16(pixels[offset + 1])
                decoded.append(isLittleEndian ? second << 8 | first : first << 8 | second)
            }
        }
        #expect(decoded == millimeters)
    }

    @Test("Sidecar writer stores mesh, counts depth frames and describes both")
    func sidecarWriter() throws {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: id)) }

        for index in 1...2 {
            CaptureDepthRecorder.write(
                CaptureDepthSample(
                    width: 2, height: 2,
                    depthMeters: [1, 2, 3, 4],
                    confidence: [0, 1, 2, 2]
                ),
                captureID: id,
                frameIndex: index
            )
        }
        let metadata = try CaptureLidarSidecarWriter.write(mesh: Self.triangleMesh, captureID: id)

        #expect(metadata.mesh?.faceCount == 3)
        #expect(metadata.mesh?.vertexCount == 7)
        #expect(metadata.mesh?.groups == ["floor", "wall"])
        #expect(metadata.depth?.frameCount == 2)
        #expect(metadata.depth?.confidenceDirectory == "confidence")
        #expect(FileManager.default.fileExists(atPath: CapturePaths.lidarMesh(for: id).path))
        #expect(FileManager.default.fileExists(
            atPath: CapturePaths.lidarDepth(for: id, index: 2).path
        ))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(
            CaptureLidarMetadata.self,
            from: Data(contentsOf: CapturePaths.lidarMetadata(for: id))
        )
        #expect(stored.mesh == metadata.mesh)
        #expect(stored.depth == metadata.depth)
        // Sidecar data stays out of the Echo-3 bundle.
        #expect(!FileManager.default.fileExists(atPath: CapturePaths.bundleRoot(for: id).path))
    }

    @Test("Without mesh or depth only the metadata file is written")
    func sidecarWithoutLidar() throws {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: id)) }
        let metadata = try CaptureLidarSidecarWriter.write(mesh: nil, captureID: id)
        #expect(metadata.mesh == nil)
        #expect(metadata.depth == nil)
        #expect(!FileManager.default.fileExists(atPath: CapturePaths.lidarMesh(for: id).path))
    }
}
