import Foundation

@MainActor
final class MenuService {
    static let shared = MenuService()
    private enum CacheKey {
        static let menuCatalog = "cosmic_menu_catalog"
        static let menuItems = "cosmic_menu_items"
    }

    private let legacyMenuNameToID: [String: String] = [
        "Dashboard": "dashboard",
        "Objects": "objects",
        "Tasks": "tasks",
        "Notifications": "notifications",
        "Calendar": "calendar",
        "Documents": "documents",
        "Profile": "profile",
        "Interior Designer": "interior-designer",
        "Food Delivery": "food-delivery",
        "Insurance": "insurance",
        "Games": "games",
        "3D Reconstruction": "reconstruction",
        "My Spaces": "spaces",
        "AI Agent": "dashboard",
    ]

    private init() {}

    func cachedCatalog() -> [AppMenuCatalogItem] {
        guard let data = UserDefaults.standard.data(forKey: CacheKey.menuCatalog),
              let decoded = try? JSONDecoder().decode([AppMenuCatalogItem].self, from: data),
              !decoded.isEmpty else {
            return AppMenuCatalog.fallback
        }

        return decoded
    }

    func cachedMenuItems() -> [AppMenuItem] {
        guard let data = UserDefaults.standard.data(forKey: CacheKey.menuItems),
              let decoded = try? JSONDecoder().decode([AppMenuItem].self, from: data),
              !decoded.isEmpty else {
            return AppMenuCatalog.buildItems(from: cachedCatalog())
        }

        return normalize(items: decoded)
    }

    func fetchCatalog() async -> [AppMenuCatalogItem] {
        do {
            let response: BackendMenuCatalogResponse = try await HTTPClient.shared.get("/menu-catalog")
            if let error = response.error, !error.isEmpty {
                return AppMenuCatalog.fallback
            }
            let catalog = response.data.isEmpty ? AppMenuCatalog.fallback : response.data
            cacheCatalog(catalog)
            return catalog
        } catch {
            return cachedCatalog()
        }
    }

    func fetchResolvedMenuItems(catalog: [AppMenuCatalogItem]) async -> [AppMenuItem] {
        let fallbackItems = AppMenuCatalog.buildItems(from: catalog)

        do {
            let response: BackendUserMenuResponse = try await HTTPClient.shared.get("/user-menu")
            if let error = response.error, !error.isEmpty {
                return fallbackItems
            }

            guard !response.data.isEmpty else {
                return fallbackItems
            }

            let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
            let configuredIDs = Set(response.data.compactMap { legacyMenuNameToID[$0.name] ?? $0.name })

            let configuredItems = response.data
                .sorted { $0.order < $1.order }
                .compactMap { entry -> AppMenuItem? in
                    let resolvedID = legacyMenuNameToID[entry.name] ?? entry.name
                    guard let catalogItem = catalogByID[resolvedID] else { return nil }
                    return catalogItem.resolvedItem(
                        section: entry.enabled ? .main : .other,
                        order: entry.order
                    )
                }

            let missingItems = catalog
                .filter { !configuredIDs.contains($0.id) }
                .map { $0.resolvedItem(section: .other, order: $0.defaultOrder) }

            let normalizedItems = normalize(items: configuredItems + missingItems)
            cacheMenuItems(normalizedItems)
            return normalizedItems
        } catch {
            let cachedItems = cachedMenuItems()
            return cachedItems.isEmpty ? fallbackItems : cachedItems
        }
    }

    func updateMenu(items: [AppMenuItem]) async throws {
        let mainItems = items
            .filter { $0.section == .main }
            .sorted { $0.order < $1.order }
        let otherItems = items
            .filter { $0.section == .other }
            .sorted { $0.order < $1.order }

        let payload = mainItems.enumerated().map { index, item in
            UpdateUserMenuPayload(name: item.id, order: index, enabled: true)
        } + otherItems.enumerated().map { index, item in
            UpdateUserMenuPayload(name: item.id, order: index, enabled: false)
        }

        let _: BackendUserMenuResponse = try await HTTPClient.shared.put("/user-menu", body: payload)
        cacheMenuItems(normalize(items: items))
    }

    func normalize(items: [AppMenuItem]) -> [AppMenuItem] {
        let mainItems = items
            .filter { $0.section == .main }
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { index, item in
                AppMenuItem(
                    id: item.id,
                    label: item.label,
                    symbolName: item.symbolName,
                    iconAssetName: item.iconAssetName,
                    iconKey: item.iconKey,
                    section: .main,
                    order: index,
                    subtitle: item.subtitle
                )
            }
        let otherItems = items
            .filter { $0.section == .other }
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { index, item in
                AppMenuItem(
                    id: item.id,
                    label: item.label,
                    symbolName: item.symbolName,
                    iconAssetName: item.iconAssetName,
                    iconKey: item.iconKey,
                    section: .other,
                    order: index,
                    subtitle: item.subtitle
                )
            }

        return mainItems + otherItems
    }

    private func cacheCatalog(_ catalog: [AppMenuCatalogItem]) {
        guard let encoded = try? JSONEncoder().encode(catalog) else { return }
        UserDefaults.standard.set(encoded, forKey: CacheKey.menuCatalog)
    }

    private func cacheMenuItems(_ items: [AppMenuItem]) {
        guard let encoded = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(encoded, forKey: CacheKey.menuItems)
    }
}
