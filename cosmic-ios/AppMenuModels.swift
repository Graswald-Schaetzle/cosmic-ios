import Foundation

enum AppMenuSection: String, Codable {
    case main
    case other
}

struct AppMenuCatalogItem: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let iconKey: String
    let defaultSection: AppMenuSection
    let defaultOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case iconKey
        case defaultSection
        case defaultOrder
    }

    var symbolName: String {
        switch iconKey {
        case "dashboard":
            return "square.grid.2x2.fill"
        case "objects":
            return "shippingbox"
        case "tasks":
            return "checkmark.circle"
        case "notifications":
            return "bell"
        case "calendar":
            return "calendar"
        case "documents":
            return "doc"
        case "profile":
            return "person"
        case "interior-designer":
            return "pencil.and.ruler.fill"
        case "food-delivery":
            return "takeoutbag.and.cup.and.straw.fill"
        case "insurance":
            return "cross.case.fill"
        case "games":
            return "gamecontroller.fill"
        case "reconstruction":
            return "cube.transparent.fill"
        case "spaces":
            return "house.lodge.fill"
        default:
            return "square.grid.2x2.fill"
        }
    }

    var iconAssetName: String? {
        switch iconKey {
        case "dashboard":
            return "menu-dashboard"
        case "objects":
            return "menu-objects"
        case "tasks":
            return "menu-tasks"
        case "notifications":
            return "menu-notifications"
        case "calendar":
            return "menu-calendar"
        case "documents":
            return "menu-documents"
        case "profile":
            return "menu-profile"
        case "reconstruction":
            return "menu-reconstruction"
        default:
            return nil
        }
    }

    var subtitle: String {
        switch id {
        case "dashboard":
            return "Matterport bleibt der räumliche Einstieg und orientiert sich an derselben Navigationslogik wie die Webapp."
        case "objects":
            return "Die Objekt- und Tag-Verwaltung folgt derselben Benennung wie im Web und bleibt der nächste mobile Ausbaupunkt."
        case "tasks":
            return "Tasks werden in derselben Struktur geführt, damit mobile und Web-Navigation nicht auseinanderlaufen."
        case "notifications":
            return "Benachrichtigungen hängen an derselben Menü-ID und erscheinen auf allen Geräten in derselben Reihenfolge."
        case "calendar":
            return "Kalender bleibt als eigener Bereich im selben Menümodell verankert."
        case "documents":
            return "Dokumente werden im mobilen Shell-Layout unter derselben Bezeichnung geführt wie in der Webapp."
        case "profile":
            return "Profil ist jetzt Teil desselben Menü-Katalogs und nicht mehr ein separates mobiles Sondermenü."
        case "interior-designer":
            return "Dieser Bereich übernimmt dieselbe Bezeichnung wie im Web und kann später mit einer nativen iOS-Ansicht gefüllt werden."
        case "food-delivery":
            return "Dieser Menüpunkt folgt jetzt derselben Taxonomie wie in der Webapp."
        case "insurance":
            return "Versicherung bleibt als synchronisierte Zusatzfunktion im gemeinsamen Menümodell enthalten."
        case "games":
            return "Games nutzt jetzt denselben Menüeintrag und dieselbe Reihenfolge wie auf dem Web."
        case "reconstruction":
            return "3D Reconstruction bleibt als technischer Bereich im gemeinsamen Menüsystem verankert."
        case "spaces":
            return "My Spaces wird jetzt über dieselbe User-Menü-Konfiguration wie in der Webapp einsortiert."
        default:
            return "Dieser Bereich ist Teil des gemeinsamen Menü-Katalogs für Web und iOS."
        }
    }
}

struct AppMenuItem: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let symbolName: String
    let iconAssetName: String?
    let iconKey: String
    let section: AppMenuSection
    let order: Int
    let subtitle: String
}

struct BackendMenuCatalogResponse: Decodable {
    let data: [AppMenuCatalogItem]
    let error: String?
}

struct BackendUserMenuItem: Decodable {
    let name: String
    let order: Int
    let enabled: Bool
}

struct BackendUserMenuResponse: Decodable {
    let data: [BackendUserMenuItem]
    let error: String?
}

struct UpdateUserMenuPayload: Encodable {
    let name: String
    let order: Int
    let enabled: Bool
}

extension AppMenuCatalogItem {
    func resolvedItem(section: AppMenuSection? = nil, order: Int? = nil) -> AppMenuItem {
        AppMenuItem(
            id: id,
            label: label,
            symbolName: symbolName,
            iconAssetName: iconAssetName,
            iconKey: iconKey,
            section: section ?? defaultSection,
            order: order ?? defaultOrder,
            subtitle: subtitle
        )
    }
}

enum AppMenuCatalog {
    static let fallback: [AppMenuCatalogItem] = [
        AppMenuCatalogItem(id: "dashboard", label: "Dashboard", iconKey: "dashboard", defaultSection: .main, defaultOrder: 0),
        AppMenuCatalogItem(id: "objects", label: "Objects", iconKey: "objects", defaultSection: .main, defaultOrder: 1),
        AppMenuCatalogItem(id: "tasks", label: "Tasks", iconKey: "tasks", defaultSection: .main, defaultOrder: 2),
        AppMenuCatalogItem(id: "notifications", label: "Notifications", iconKey: "notifications", defaultSection: .main, defaultOrder: 3),
        AppMenuCatalogItem(id: "calendar", label: "Calendar", iconKey: "calendar", defaultSection: .main, defaultOrder: 4),
        AppMenuCatalogItem(id: "documents", label: "Documents", iconKey: "documents", defaultSection: .main, defaultOrder: 5),
        AppMenuCatalogItem(id: "profile", label: "Profile", iconKey: "profile", defaultSection: .main, defaultOrder: 6),
        AppMenuCatalogItem(id: "interior-designer", label: "Interior Designer", iconKey: "interior-designer", defaultSection: .other, defaultOrder: 0),
        AppMenuCatalogItem(id: "food-delivery", label: "Food Delivery", iconKey: "food-delivery", defaultSection: .other, defaultOrder: 1),
        AppMenuCatalogItem(id: "insurance", label: "Insurance", iconKey: "insurance", defaultSection: .other, defaultOrder: 2),
        AppMenuCatalogItem(id: "games", label: "Games", iconKey: "games", defaultSection: .other, defaultOrder: 3),
        AppMenuCatalogItem(id: "reconstruction", label: "3D Reconstruction", iconKey: "reconstruction", defaultSection: .other, defaultOrder: 4),
        AppMenuCatalogItem(id: "spaces", label: "My Spaces", iconKey: "spaces", defaultSection: .other, defaultOrder: 5),
    ]

    static func buildItems(from catalog: [AppMenuCatalogItem]) -> [AppMenuItem] {
        catalog.map { $0.resolvedItem() }
    }
}
