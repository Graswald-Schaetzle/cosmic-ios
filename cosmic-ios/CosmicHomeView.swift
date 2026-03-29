import SwiftUI

private enum HomeSheet: String, Identifiable {
    case history
    case spaces
    case profile

    var id: String { rawValue }
}

private enum QuickAction: String, CaseIterable, Identifiable {
    case scan
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan:
            return "Scan"
        case .history:
            return "History"
        }
    }

    var symbolName: String {
        switch self {
        case .scan:
            return "camera.viewfinder"
        case .history:
            return "clock.arrow.circlepath"
        }
    }
}

struct CosmicHomeView: View {
    @ObservedObject private var authService = AuthService.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var spaces: [BackendSpace] = []
    @State private var selectedSpaceID: Int?
    @State private var isLoadingSpaces = false
    @State private var spacesErrorMessage: String?

    @State private var menuCatalog: [AppMenuCatalogItem] = AppMenuCatalog.fallback
    @State private var menuItems: [AppMenuItem] = AppMenuCatalog.buildItems(from: AppMenuCatalog.fallback)
    @State private var isLoadingMenu = false
    @State private var menuErrorMessage: String?
    @State private var selectedMenuID = "dashboard"

    @State private var activeSheet: HomeSheet?
    @State private var showScanner = false
    @State private var showMorePanel = false
    @State private var viewerIsLoading = true
    @State private var viewerErrorMessage: String?

    private let mainMenuWidth: CGFloat = 76
    private let menuSpacing: CGFloat = 16
    private let trailingMenuPadding: CGFloat = 12
    private let panelToMenuGap: CGFloat = 20

    init() {
        let cachedCatalog = MenuService.shared.cachedCatalog()
        let cachedItems = MenuService.shared.cachedMenuItems()

        _menuCatalog = State(initialValue: cachedCatalog)
        _menuItems = State(initialValue: cachedItems)
        _selectedMenuID = State(initialValue: cachedItems.first(where: { $0.section == .main })?.id ?? cachedItems.first?.id ?? "dashboard")
    }

    var body: some View {
        ZStack {
            viewerLayer
            viewerChrome
        }
        .background(Color.black)
        .overlay(alignment: .trailing) {
            trailingMenu
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .history:
                ScanHistoryView()
            case .spaces:
                SpacesSheetView(
                    spaces: spaces,
                    selectedSpaceID: $selectedSpaceID,
                    isLoading: isLoadingSpaces,
                    errorMessage: spacesErrorMessage,
                    onReload: {
                        Task { await loadSpaces() }
                    }
                )
                .presentationDetents([.medium, .large])
            case .profile:
                ProfileSheetView {
                    authService.signOut()
                }
                .presentationDetents([.medium])
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            ARMeshScannerView(showsDismissButton: true)
        }
        .task {
            await loadHomeState()
        }
    }

    private var viewerLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.07, blue: 0.09),
                    Color(red: 0.10, green: 0.11, blue: 0.13),
                    Color(red: 0.04, green: 0.05, blue: 0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let showcaseURL = activeViewerURL {
                MatterportWebView(
                    url: showcaseURL,
                    isLoading: $viewerIsLoading,
                    errorMessage: $viewerErrorMessage
                )
                .ignoresSafeArea()
            } else {
                MatterportConfigurationPlaceholder()
                    .padding(24)
            }

            viewerOverlayGradient
                .ignoresSafeArea()

            if viewerIsLoading, activeViewerURL != nil {
                loadingBadge
            }
        }
    }

    private var viewerOverlayGradient: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.48),
                Color.black.opacity(0.12),
                Color.black.opacity(0.54)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .allowsHitTesting(false)
    }

    private var loadingBadge: some View {
        VStack {
            ProgressView("Matterport wird geladen…")
                .tint(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
        }
        .padding(.top, 24)
    }

    private var viewerChrome: some View {
        ZStack {
            selectedPanelCard
                .offset(x: -(reservedTrailingWidth / 2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
    }

    private var selectedPanelCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                menuIcon(
                    assetName: selectedMenuItem.iconAssetName,
                    symbolName: selectedMenuItem.symbolName,
                    foregroundColor: .white,
                    size: 20
                )

                Text(selectedMenuItem.label)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            Text(selectedMenuItem.subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))

            panelContent

            if let menuErrorMessage {
                Text(menuErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange.opacity(0.92))
            }
        }
        .padding(18)
        .frame(maxWidth: panelCardMaxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.26))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedMenuItem.id {
        case "dashboard":
            dashboardSpaceSummary
            dashboardActions
        case "spaces":
            spacesPanelContent
        case "profile":
            profilePanelContent
        case "reconstruction":
            reconstructionPanelContent
        default:
            Text("Die mobile Shell nutzt jetzt dieselbe Menü-ID und dieselbe Bezeichnung wie die Webapp. Der native Inhalt kann darauf inkrementell aufsetzen, ohne dass Navigation und Reihenfolge wieder auseinanderlaufen.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.68))
        }
    }

    @ViewBuilder
    private var dashboardSpaceSummary: some View {
        if let selectedSpace {
            VStack(alignment: .leading, spacing: 10) {
                Text(selectedSpace.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 8) {
                    dashboardMetric("\(selectedSpace.roomCount) Räume")
                    dashboardMetric("\(selectedSpace.locationCount) Locations")

                    if let status = selectedSpace.latestJob?.status {
                        dashboardMetric(status.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                }

                if let description = selectedSpace.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(3)
                } else if selectedSpaceMatterportURL != nil {
                    Text("Dieser Space liefert bereits eine eigene Matterport-Konfiguration und überschreibt damit die globale App-Einstellung.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.68))
                } else {
                    Text("Dieser Space ist in der mobilen Shell ausgewählt. Die Matterport-Zuordnung selbst bleibt aktuell noch global konfiguriert.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.68))
                }
            }
        } else if isLoadingSpaces {
            Text("Spaces werden geladen…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.68))
        } else if let spacesErrorMessage {
            Text(spacesErrorMessage)
                .font(.footnote)
                .foregroundStyle(.orange.opacity(0.9))
        } else {
            Text("Für diesen Account wurden noch keine Spaces geladen.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.68))
        }
    }

    private var spacesPanelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            dashboardSpaceSummary

            Button {
                activeSheet = .spaces
            } label: {
                Label("Open My Spaces", systemImage: "building.2")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    private var profilePanelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profil ist jetzt Teil desselben Menüsystems wie im Web. Der Logout bleibt direkt in der mobilen Shell erreichbar.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.68))

            HStack(spacing: 10) {
                Button {
                    activeSheet = .profile
                } label: {
                    Label("Open Profile", systemImage: "person.crop.circle")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white)
                }

                Button(role: .destructive) {
                    authService.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
        }
    }

    private var reconstructionPanelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = selectedSpace?.latestJob?.status {
                dashboardMetric(status.replacingOccurrences(of: "_", with: " ").capitalized)
            }

            Text("Die Rekonstruktionsfunktion ist als eigener Menüpunkt jetzt zwischen Web und iOS synchronisierbar. Die Reihenfolge folgt der User-Konfiguration aus `/user-menu`.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.68))
        }
    }

    private func dashboardMetric(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.10), in: Capsule())
    }

    private var dashboardActions: some View {
        HStack(spacing: 10) {
            Button {
                showScanner = true
            } label: {
                Label("Start Scan", systemImage: "camera.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
            }

            Button {
                activeSheet = .history
            } label: {
                Label("History", systemImage: "clock")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    private var trailingMenu: some View {
        HStack(spacing: 16) {
            if showMorePanel {
                morePanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            mainMenu
        }
        .padding(.trailing, 12)
        .padding(.vertical, 20)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: showMorePanel)
    }

    private var mainMenu: some View {
        VStack(spacing: 12) {
            ForEach(mainMenuItems) { item in
                menuButton(
                    title: item.label,
                    iconAssetName: item.iconAssetName,
                    symbolName: item.symbolName,
                    isSelected: selectedMenuID == item.id,
                    expanded: false
                ) {
                    selectedMenuID = item.id
                    showMorePanel = false
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.2))
                .padding(.horizontal, 8)

            menuButton(
                title: showMorePanel ? "Close" : "More",
                symbolName: showMorePanel ? "xmark" : "plus",
                isSelected: showMorePanel,
                expanded: false
            ) {
                showMorePanel.toggle()
            }
        }
        .padding(12)
        .frame(width: 76)
        .background(menuBackground)
    }

    private var morePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("More")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)

            if isLoadingMenu {
                ProgressView()
                    .tint(.white)
                    .padding(.horizontal, 8)
            }

            ForEach(otherMenuItems) { item in
                menuButton(
                    title: item.label,
                    iconAssetName: item.iconAssetName,
                    symbolName: item.symbolName,
                    isSelected: selectedMenuID == item.id,
                    expanded: true
                ) {
                    selectedMenuID = item.id
                }
            }

            if !otherMenuItems.isEmpty {
                Divider()
                    .overlay(Color.white.opacity(0.2))
            }

            ForEach(QuickAction.allCases) { action in
                menuButton(
                    title: action.title,
                    symbolName: action.symbolName,
                    isSelected: false,
                    expanded: true
                ) {
                    handleQuickAction(action)
                }
            }

        }
        .padding(12)
        .frame(width: 220)
        .background(menuBackground)
    }

    private var menuBackground: some View {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(Color(red: 0.18, green: 0.18, blue: 0.18).opacity(0.52))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }

    private func menuButton(
        title: String,
        iconAssetName: String? = nil,
        symbolName: String,
        isSelected: Bool,
        expanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                menuIcon(
                    assetName: iconAssetName,
                    symbolName: symbolName,
                    foregroundColor: isSelected ? .black : .white.opacity(0.92),
                    size: 17
                )

                if expanded {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.92))
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isSelected ? Color.white : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .frame(width: expanded ? nil : 52)
    }

    @ViewBuilder
    private func menuIcon(
        assetName: String?,
        symbolName: String,
        foregroundColor: Color,
        size: CGFloat
    ) -> some View {
        if let assetName {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(foregroundColor)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 24, height: 24)
        }
    }

    private func handleQuickAction(_ action: QuickAction) {
        showMorePanel = false

        switch action {
        case .scan:
            showScanner = true
        case .history:
            activeSheet = .history
        }
    }

    private var selectedSpace: BackendSpace? {
        guard let selectedSpaceID else { return nil }
        return spaces.first(where: { $0.spaceId == selectedSpaceID })
    }

    private var selectedSpaceMatterportURL: URL? {
        guard let selectedSpace else { return nil }

        return Config.makeMatterportShowcaseURL(
            showcaseURLString: selectedSpace.matterportShowcaseURLString,
            modelID: selectedSpace.matterportModelID,
            sdkKey: Config.matterportSDKKey
        )
    }

    private var activeViewerURL: URL? {
        selectedSpaceMatterportURL ?? Config.matterportShowcaseURL
    }

    private var selectedMenuItem: AppMenuItem {
        menuItems.first(where: { $0.id == selectedMenuID }) ?? AppMenuCatalog.buildItems(from: menuCatalog).first ?? AppMenuCatalog.buildItems(from: AppMenuCatalog.fallback)[0]
    }

    private var mainMenuItems: [AppMenuItem] {
        menuItems
            .filter { $0.section == .main }
            .sorted { $0.order < $1.order }
    }

    private var otherMenuItems: [AppMenuItem] {
        menuItems
            .filter { $0.section == .other }
            .sorted { $0.order < $1.order }
    }

    private func loadHomeState() async {
        await loadSpaces()
        await loadMenu()
    }

    private func loadMenu() async {
        guard !isLoadingMenu else { return }

        isLoadingMenu = true
        menuErrorMessage = nil
        defer { isLoadingMenu = false }

        let catalog = await MenuService.shared.fetchCatalog()
        menuCatalog = catalog
        let resolvedItems = await MenuService.shared.fetchResolvedMenuItems(catalog: catalog)
        menuItems = MenuService.shared.normalize(items: resolvedItems)

        if menuItems.contains(where: { $0.id == selectedMenuID }) {
            return
        }

        if let firstMainItem = mainMenuItems.first {
            selectedMenuID = firstMainItem.id
        } else if let firstItem = menuItems.first {
            selectedMenuID = firstItem.id
        } else {
            selectedMenuID = "dashboard"
            menuErrorMessage = "Das Menü konnte nicht geladen werden. Die App verwendet die lokale Fallback-Konfiguration."
        }
    }

    private func loadSpaces() async {
        guard !isLoadingSpaces else { return }

        isLoadingSpaces = true
        spacesErrorMessage = nil
        defer { isLoadingSpaces = false }

        do {
            let fetchedSpaces = try await SpaceService.shared.fetchSpaces()
            spaces = fetchedSpaces

            if let selectedSpaceID,
               fetchedSpaces.contains(where: { $0.spaceId == selectedSpaceID }) {
                return
            }

            selectedSpaceID = fetchedSpaces.first?.spaceId
        } catch {
            spacesErrorMessage = error.localizedDescription
        }
    }

    private var reservedTrailingWidth: CGFloat {
        mainMenuWidth + trailingMenuPadding + panelToMenuGap + (showMorePanel ? 220 + menuSpacing : 0)
    }

    private var panelCardMaxWidth: CGFloat {
        horizontalSizeClass == .compact ? 300 : 360
    }
}

private struct MatterportConfigurationPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Matterport noch nicht konfiguriert", systemImage: "cube.transparent")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text("Setze in den Build-Settings entweder `MATTERPORT_SHOWCASE_URL` oder `MATTERPORT_MODEL_ID` plus optional `MATTERPORT_SDK_KEY`, damit der 3D-Viewer direkt in der App startet.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.78))

            Text("Sobald diese Werte vorhanden sind, öffnet die App nach dem Login den Matterport Space statt der Kamera.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.64))
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct SpacesSheetView: View {
    let spaces: [BackendSpace]
    @Binding var selectedSpaceID: Int?
    let isLoading: Bool
    let errorMessage: String?
    let onReload: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && spaces.isEmpty {
                    ProgressView("Spaces werden geladen…")
                } else if let errorMessage, spaces.isEmpty {
                    ContentUnavailableView(
                        "Spaces konnten nicht geladen werden",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if spaces.isEmpty {
                    ContentUnavailableView(
                        "Keine Spaces gefunden",
                        systemImage: "building.2",
                        description: Text("Sobald Spaces im Backend vorhanden sind, können sie hier ausgewählt werden.")
                    )
                } else {
                    List(spaces) { space in
                        Button {
                            selectedSpaceID = space.spaceId
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selectedSpaceID == space.spaceId ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedSpaceID == space.spaceId ? .green : .secondary)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(space.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    HStack(spacing: 8) {
                                        spacesBadge("\(space.roomCount) Räume")
                                        spacesBadge("\(space.locationCount) Locations")
                                    }

                                    if let status = space.latestJob?.status {
                                        Text("Letzte Rekonstruktion: \(status.replacingOccurrences(of: "_", with: " "))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let description = space.description, !description.isEmpty {
                                        Text(description)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }

                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("My Spaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Neu laden", action: onReload)
                }
            }
        }
    }

    private func spacesBadge(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private struct ProfileSheetView: View {
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label("Profile", systemImage: "person.crop.circle")
                    .font(.title3.weight(.semibold))

                Text("Der Logout bleibt direkt aus der gemeinsamen App-Shell erreichbar, ohne den räumlichen Einstieg zu verlassen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    onLogout()
                    dismiss()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding(24)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
