import Foundation

@MainActor
final class SpaceService {
    static let shared = SpaceService()

    private init() {}

    func fetchSpaces() async throws -> [BackendSpace] {
        let response: SpaceListResponse = try await HTTPClient.shared.get("/spaces")
        return response.data
    }
}
