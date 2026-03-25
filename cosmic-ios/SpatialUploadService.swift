import Foundation
import RoomPlan
import simd

/// Serialisiert einen CapturedRoom (RoomPlan-Scan) in das Backend-Format
/// und sendet ihn an POST /spaces/:id/spatial-scan.
@MainActor
final class SpatialUploadService {

    static let shared = SpatialUploadService()

    private let http = HTTPClient.shared

    private init() {}

    // MARK: - Public API

    /// Lädt alle erkannten Objekte und Flächen eines RoomPlan-Scans ans Backend hoch.
    /// - Parameters:
    ///   - capturedRoom: Der fertig gebaute CapturedRoom (aus RoomBuilder).
    ///   - spaceId: Die Backend-ID des zugehörigen Spaces.
    ///   - floorId: Optionale Etagen-ID.
    ///   - roomId: Optionale Raum-ID.
    /// - Returns: Die Serverantwort mit Anzahl gespeicherter Objekte und Flächen.
    func upload(capturedRoom: CapturedRoom, spaceId: Int, floorId: Int? = nil, roomId: Int? = nil) async throws -> SpatialScanResponse {
        let sessionId = UUID().uuidString
        let payload = buildPayload(
            from: capturedRoom,
            spaceId: spaceId,
            floorId: floorId,
            roomId: roomId,
            sessionId: sessionId
        )
        return try await http.post("/spaces/\(spaceId)/spatial-scan", body: payload)
    }

    // MARK: - Private: Payload Builder

    private func buildPayload(
        from room: CapturedRoom,
        spaceId: Int,
        floorId: Int?,
        roomId: Int?,
        sessionId: String
    ) -> SpatialScanPayload {
        let objects = room.objects.map(extractObject)

        var surfaces: [RoomSurfacePayload] = []
        surfaces += room.walls.map    { makeSurface($0.transform, dims: $0.dimensions, type: "wall",    confidence: $0.confidence.apiString) }
        surfaces += room.floors.map   { makeSurface($0.transform, dims: $0.dimensions, type: "floor",   confidence: $0.confidence.apiString) }
        surfaces += room.doors.map    { makeSurface($0.transform, dims: $0.dimensions, type: "door",    confidence: "medium") }
        surfaces += room.windows.map  { makeSurface($0.transform, dims: $0.dimensions, type: "window",  confidence: "medium") }
        surfaces += room.openings.map { makeSurface($0.transform, dims: $0.dimensions, type: "opening", confidence: "medium") }

        return SpatialScanPayload(
            spaceId: spaceId,
            floorId: floorId,
            roomId: roomId,
            scanSessionId: sessionId,
            objects: objects,
            surfaces: surfaces
        )
    }

    // MARK: - Private: Element Extractors

    private func extractObject(_ object: CapturedRoom.Object) -> SpatialObjectPayload {
        let (pos, quat) = decompose(object.transform)
        let dims = object.dimensions
        return SpatialObjectPayload(
            category:   object.category.apiString,
            posX:       Double(pos.x),
            posY:       Double(pos.y),
            posZ:       Double(pos.z),
            dimWidth:   Double(dims.x),
            dimHeight:  Double(dims.y),
            dimDepth:   Double(dims.z),
            rotX:       Double(quat.vector.x),
            rotY:       Double(quat.vector.y),
            rotZ:       Double(quat.vector.z),
            rotW:       Double(quat.vector.w),
            confidence: object.confidence.apiString,
            source:     "roomplan"
        )
    }

    private func makeSurface(_ transform: simd_float4x4, dims: simd_float3, type surfaceType: String, confidence: String) -> RoomSurfacePayload {
        let (pos, quat) = decompose(transform)
        return RoomSurfacePayload(
            surfaceType: surfaceType,
            posX:        Double(pos.x),
            posY:        Double(pos.y),
            posZ:        Double(pos.z),
            dimWidth:    Double(dims.x),
            dimHeight:   Double(dims.y),
            dimDepth:    Double(dims.z),
            rotX:        Double(quat.vector.x),
            rotY:        Double(quat.vector.y),
            rotZ:        Double(quat.vector.z),
            rotW:        Double(quat.vector.w),
            confidence:  confidence
        )
    }

    /// Extrahiert Position und Orientierung aus einer 4×4 Transformationsmatrix.
    private func decompose(_ m: simd_float4x4) -> (position: SIMD3<Float>, quaternion: simd_quatf) {
        let position = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let quaternion = simd_quaternion(m)
        return (position, quaternion)
    }
}
