# Plan: Redesign der Cosmic-iOS-App im Liquid-Glass-Stil (iOS 26)

## Übergabe / Weitermachen (für neue Sessions zuerst lesen)

**Stand (14.11.2026):** Phase 0 (Prototyp) und Phase 1 (Fundament) fertig, Phase 1 kompiliert ohne Änderungen mit
Xcode 27.2 (iOS-27.2-SDK, Deployment Target bleibt iOS 26.0). Phase 2 (App-Shell) umgesetzt und für Simulator und
Gerät gebaut, aber **noch nicht im Simulator oder auf dem iPhone angesehen**. Die Paket-Tests liefen am 14.11. nicht,
weil `~/Library/Developer/CoreSimulator/Devices` auf die externe Platte `/Volumes/T9` verlinkt ist; ohne die Platte
startet kein Simulator.

**Prototyp:** `docs/design/cosmic-ios-redesign.html` im Browser öffnen (klickbar, maßgeblich für Layout, Texte
und Abstände). Online-Kopie: https://claude.ai/artifact/5zKVdj8vnpHrdXnLGKYJ49 (privat). Im Prototyp ist der
Akzent "Silber" der entschiedene; Supernova/Nebula/Pulsar sind verworfene Varianten.

**Entschieden (nicht neu diskutieren):**
- iOS 26 als Mindestversion, Liquid Glass direkt aus SwiftUI, keine Fallback-Pfade, keine UI-Library.
- App = Scan-App + Space-Begleiter (Home, Captures, Scan, Profil). Aufgaben/Dokumente bleiben in der Web-App.
- 3D-Ansicht über den eingebetteten Web-Splat-Viewer (WKWebView), nicht nativ.
- Neutral: Glasflächen ohne Tönung, graue Chips, kein Orange. Einziger Akzent mattes Silber (kein Chrome-Glanz,
  kein harter Lichtstrich), dunkle Schrift darauf, nur auf Haupt-Button, Scan-Button, aktivem Tab.
- Alle UI-Texte englisch.
- Live-Scan ohne Prozentwerte für Wände/Boden/Decke; nur LiDAR-Netz und ein Hinweis aus der Lückenerkennung.

**Phase 1 enthält:** iOS 26 in `project.pbxproj` und `Packages/CosmicCapture/Package.swift` (swift-tools 6.2,
`.iOS(.v26)`); `Cosmic/CosmicDesign.swift` (Tokens, `.cosmicPrimary`, `.cosmicSecondary`, `cosmicGlassPanel()`);
`CosmicGlass.swift` gelöscht; `CameraChromeBackground`/`GlassControlBackground` auf `glassEffect`; `Theme.primary`
= Silber; `cosmic-ios/AppModel.swift` (Spaces, gemerkte Auswahl, Captures, `activeWork` für die Upload-Leiste),
noch nicht in der App verwendet.

**Phase 2 enthält:** `RootView.swift` (TabView Home/Captures, Scan-Tab mit Rolle `.search`, ab iOS 27 `.prominent`,
dessen Auswahl abgefangen wird und den Capture-Ablauf öffnet; `.tabViewBottomAccessory(isEnabled:)` aus
`AppModel.activeWork`, erst ab iOS 26.1, unter 26.0 keine Leiste; `.toolbarTitleMenu` mit Space-Picker; Avatar →
`ProfileView.swift`), einfaches `SpaceHomeView.swift` (Raumnamen aus `/spaces`, leere Zustände), `RoomCapturesView`
ohne eigenen `NavigationStack`, Polling der Echo-3-Jobs in `AppModel.pollProcessing()`, App immer dunkel.
Gelöscht: `CosmicHomeView.swift`, `MatterportWebView.swift`, `AppMenuModels.swift`, `MenuService.swift`, Matterport in
`Config.swift`. Bewusst weggelassen, weil es dafür noch keine Daten/Endpunkte gibt: "New space", E-Mail im Profil,
Mitteilungen, "Open web app".

**Nächste Schritte:**
0. Phase 2 im Simulator prüfen (T9-Platte anschließen): Scan-Tab bleibt nicht ausgewählt, Title-Menü bei großem
   Titel, Bottom Accessory während eines Uploads.
1. Bauen und testen: im Ordner `Packages/CosmicCapture`
   `xcodebuild -scheme CosmicCapture -destination 'platform=iOS Simulator,name=iPhone 17' test`, danach App für
   Simulator und Gerät bauen. Compilerfehler zuerst beheben (v. a. `glassEffect`-Aufrufe, Swift-6-Concurrency).
2. Phase 2 (App-Shell) laut Abschnitt unten: `RootView.swift` mit `TabView` (Home, Captures), abgesetztem
   Scan-Button, `.tabViewBottomAccessory` aus `AppModel.activeWork`, Space-Wechsel per `.toolbarTitleMenu`,
   Profil-Sheet; ersetzt `CosmicHomeView` in `ContentView.swift`.
3. Danach Phasen 3–6 in der Reihenfolge unten. Backend/Frontend-Abhängigkeiten (Raumliste, Embed-Modus des
   Viewers) jeweils zuerst in `cosmic-backend` bzw. `cosmic-webapp-frontend`.

## Context

Die heutige App-Oberfläche passt nicht mehr zum Produkt:
- `CosmicHomeView.swift` (794 Zeilen) ist eine Kopie der Web-Shell: Matterport-WebView als Hintergrund, rechte
  Icon-Leiste mit "More"-Panel, eine zentrale Karte mit Platzhaltertexten ("Die mobile Shell nutzt jetzt dieselbe
  Menü-ID …"). Matterport wird ersetzt, die meisten Menüpunkte haben in der App keinen Inhalt.
- Die eigentliche Aufgabe der App (Räume aufnehmen, hochladen, Ergebnis ansehen) ist hinter "Start Scan"/"History"
  versteckt. Sprachen sind gemischt (Deutsch/Englisch), Login ist ein Standardformular.
- Glas wird von Hand nachgebaut (`.ultraThinMaterial` + Tönung + Rand, `CosmicGlass.swift`, `Theme.swift`).

Ziel: Neuaufbau nach Apples aktuellem Design (Liquid Glass, iOS 26) mit Standard-SwiftUI-Komponenten. Die App wird
**Scan-App + Space-Begleiter**: Space sehen, Räume aufnehmen, Upload/Berechnung verfolgen, fertigen Splat ansehen.
Aufgaben, Dokumente usw. bleiben in der Web-App.

Entscheidungen des Nutzers (13.11.2026):
- Mindestversion **iOS 26** (statt iOS 18), echtes Liquid Glass ohne Fallback-Pfade.
- Rolle: **Scan-App + Space-Begleiter**.
- 3D-Ansicht: **Web-Splat-Viewer per WKWebView einbetten**, native Glas-UI drumherum.
- Entwürfe zuerst als **klickbarer HTML-Prototyp**, dann Umsetzung. Prototyp (privat):
  https://claude.ai/artifact/5zKVdj8vnpHrdXnLGKYJ49

## Werkzeuge und Vorlagen von Apple

Es braucht keine Fremd-Library: Liquid Glass *ist* SwiftUI ab iOS 26.
- SwiftUI-APIs: `TabView` mit `Tab` (Glas-Tab-Bar, `.tabBarMinimizeBehavior(.onScrollDown)`),
  `.tabViewBottomAccessory` (Mini-Player-Leiste, hier für Upload-Fortschritt), `.glassEffect()`,
  `GlassEffectContainer` + `.glassEffectID` (morphende Glas-Buttons), `.buttonStyle(.glass/.glassProminent)`,
  `ToolbarSpacer`, `.toolbarTitleMenu` (Space-Wechsel), Sheets mit Detents (werden automatisch gläsern),
  `.backgroundExtensionEffect()` für randlose Bilder.
- Apple-Ressourcen: Human Interface Guidelines (Abschnitt Materials/Liquid Glass), Sample "Landmarks: Building an app
  with Liquid Glass", Apple Design Resources (iOS-26-UI-Kit für Figma/Sketch), SF Symbols 7, **Icon Composer** für das
  mehrschichtige App-Icon.
- Beim Umsetzen aktuelle API-Doku über Context7 nachschlagen (nicht aus dem Gedächtnis).

## Informationsarchitektur (neu)

```
TabView (Liquid-Glass-Tab-Bar, minimiert beim Scrollen)
├── Tab "Zuhause"      SpaceHomeView     – aktueller Space: Vorschau, Stockwerke, Räume mit Status
├── Tab "Aufnahmen"    CapturesView      – lokale Captures + Uploads, gruppiert nach Status
└── Tab "Scannen"      (role .search-artig abgesetzt, runder Glas-Button rechts) → startet Scan-Ablauf
Bottom Accessory: "Wohnzimmer · wird berechnet · 62 %"  (nur wenn ein Upload/Job läuft)
Toolbar: Titel = Space-Name mit Title-Menü (Space wechseln) · rechts Avatar → Profil-Sheet
```

## Skizzen der Hauptscreens

```
 Zuhause                         Raum                            Raum-Karte (Sheet, vor Scan)
┌───────────────────────┐      ┌───────────────────────┐      ┌───────────────────────┐
│ Wohnung Mitte ▾    (◯)│      │ ‹ (glas)        ⋯ (glas)│     │                       │
│ ┌───────────────────┐ │      │                       │      │ ───────────────────── │
│ │  3D-Vorschau      │ │      │    Splat-Viewer        │      │ Neuer Raum            │
│ │  (Startraum)      │ │      │    (WKWebView,         │      │ [ Name: Küche       ] │
│ └───────────────────┘ │      │     vollflächig)       │      │ Stockwerk: (EG)(OG)   │
│ (EG)(OG)(DG)  ← Glas  │      │                       │      │ ☐ Licht an            │
│ ┌──────┐ ┌──────┐     │      │ ┌───────────────────┐ │      │ ☐ Tür geschlossen     │
│ │Wohnz.│ │Küche │     │      │ │Wohnzimmer  ● fertig│ │      │ ☐ Niemand im Raum     │
│ │●fertig│ │◐ 62% │     │      │ │Aufg. 14.11.  [Neu ]│ │      │                       │
│ └──────┘ └──────┘     │      │ └───────────────────┘ │      │ [   Scan starten    ] │
│ ┌──────┐ ┌ ─ ─ ─┐     │      └───────────────────────┘      └───────────────────────┘
│ │Bad   │ │ + Raum│     │
│ └──────┘ └ ─ ─ ─┘     │
│ ⟳ Küche wird berechnet│ ← Bottom Accessory
│ (⌂ Zuhause)(▤ Aufn.) (◉)│ ← Glas-Tab-Bar + Scan-Button
└───────────────────────┘
```

Weitere Screens: Login (randloses Splat-Video/Verlauf im Hintergrund, Glas-Karte mit E-Mail/Passwort,
`.glassProminent`-Button), Profil-Sheet (Konto, Spaces, Abmelden), leere Zustände mit `ContentUnavailableView`
("Noch kein Raum – nimm deinen ersten Raum auf").
Scan-Ablauf (Paket `CosmicCapture`): Live-Ansicht mit gläsernen Steuerelementen (`GlassEffectContainer`, Aufnahme-Button
morpht zu Stopp/Fertig), Review, Tür markieren, "Weiter im nächsten Raum" – Ablauf laut `docs/echo3-capture-plan.md`.

Farben (Feedback 13.11.: "zu viele Farben, neutraler" und "kein Orange, kosmische Farben wie eine Supernova"):
**neutrale Basis + ein kosmischer Akzent**.
- Basis monochrom: System-Glas ohne Tönung, Text weiß/grau, Status-Chips grau mit kleinem Punkt/Symbol statt farbiger
  Flächen, Raum-Chips grau, Profil-Icons ohne bunte Kacheln.
- Orange `#FFA600` entfällt als Akzent (auch in `Theme.primary` des Capture-Pakets).
- Akzent aus Supernova-Emissionsfarben, sparsam eingesetzt (Haupt-Button, Scan-Button, aktiver Tab, laufender
  Fortschritt, Logo, Tür-Markierung). Drei Varianten im Prototyp umschaltbar, der Nutzer wählt eine:
  1. **Supernova** – Verlauf Violett `#7B5CFF` → Magenta `#E14BD8` → Sauerstoff-Türkis `#3EE6D2` (Hauptvorschlag)
  2. **Nebula** – Wasserstoff-Pink `#FF5C8A` → Violett `#8A6BFF`
  3. **Pulsar** – einfarbig Sauerstoff-Türkis `#3EE6D2` (OIII-Linie, wie in Nebel-Aufnahmen)
- Bedeutungsfarben bleiben klein: Fehler/Löschen `#FF6B6B`, Aufnahme-Punkt rot, Lücken im Review.
- Immer dunkles Schema (3D-Inhalt), SF-Pro/System-Schrift mit Dynamic Type. In SwiftUI: Akzent als `Color`/
  `MeshGradient` in `Theme`, `.tint(...)` am Root, Verlauf nur auf Haupt-Button und Logo.

Neutral + Akzent-Umschalter ist im Prototyp umgesetzt (Version 2). Version 5 (Entscheidung): Akzent **Silber**, matt und hell
(`#ECEEF1` → `#CBCFD4`, dunkle Schrift), ohne Chrome-Lichtkante; Glasflächen bleiben Glas. In SwiftUI als sanfter
`LinearGradient` nur auf Haupt-Button, Scan-Button und aktivem Tab. **Gesamte App-UI auf Englisch** (auch Rahmen,
nicht nur Capture-Ablauf) – damit ist der offene Punkt Sprache entschieden.

Live-Scan (Feedback 13.11.: Prozentwerte für Wände/Boden/Decke "technisch zu umständlich, kaum Mehrwert"):
Die Leiste mit Prozenten entfällt. Der Capture-Kern liefert ohnehin keine Prozente, sondern Flächen-Patches mit
Evidenz (`CaptureSurfaceCoverage`) und Lücken (`CaptureCoverageGapAnalyzer`, `CaptureLiveCoverageGaps`). Im UI bleibt nur,
was schon existiert: das eingefärbte LiDAR-Netz und der eine Hinweis oben (z. B. "Look up to reveal the ceiling",
Texte aus `CaptureRoomOverview.swift`). Der Screen wird dadurch ruhiger: Kamera, Netz, ein Hinweis, Aufnahme-Button.

Im Prototyp umgesetzt (Version 3).

## Umsetzung in Phasen

**Phase 0 – Klickbarer HTML-Prototyp** (nach Freigabe zuerst)
- Eine HTML-Seite mit iPhone-Rahmen, Liquid-Glass-Nachbau per CSS (`backdrop-filter`, Lichtkanten), alle oben
  skizzierten Screens zum Durchklicken, als privates Artifact. Feedback einholen, bevor Swift-Code entsteht.

**Phase 1 – Fundament**
- `IPHONEOS_DEPLOYMENT_TARGET = 26.0` in `cosmic-ios.xcodeproj/project.pbxproj`, `platforms: [.iOS(.v26)]` in
  `Packages/CosmicCapture/Package.swift`; `CLAUDE.md` und `docs/echo3-capture-plan.md` (Mindestversion) anpassen.
- `Theme.swift` auf Akzent-/Statusfarben und Radien reduzieren; `CosmicGlass.swift` → `.glassEffect(in:)`
  (Reduce Transparency/Increase Contrast übernimmt das System). `PrimaryActionButtonStyle`/`SecondaryActionButtonStyle`
  in `App/Components.swift` durch `.glassProminent`/`.glass` ersetzen.
- Neuer `AppModel` (`@Observable`): Spaces, gewählter Space, laufende Uploads; nutzt `SpaceService`,
  `RoomCaptureUploadService`, `CosmicCaptureStore`, `AuthService` unverändert.

**Phase 2 – App-Shell**
- `RootView.swift` (TabView, Bottom Accessory, Toolbar mit Space-Title-Menü und Avatar) ersetzt `CosmicHomeView`
  in `ContentView.swift`. Die rechte Menüleiste, das More-Panel, `MenuService`-Navigation und der Matterport-Hintergrund
  entfallen aus der App (`MatterportWebView.swift`, `AppMenuModels.swift`, `MenuService.swift` danach ungenutzt → löschen).

**Phase 3 – Zuhause und Aufnahmen**
- `SpaceHomeView.swift`: Vorschau des Startraums, Stockwerk-Auswahl, Raum-Raster mit Status-Chips, "+ Raum".
  Datenquelle prüfen: Rooms/Floors des Space und Status aus `/room-captures`; fehlt ein Listen-Endpunkt, zuerst im
  Backend ergänzen (Backend vor App).
- `RoomCapturesView.swift` wird zum Tab "Aufnahmen" (gleiche Logik, neue Darstellung, gruppiert nach Status).
- Upload-Fortschritt als `.tabViewBottomAccessory`.

**Phase 4 – Raum-Ansicht mit Web-Viewer**
- `SplatWebView.swift`: WKWebView-Wrapper (Muster aus `MatterportWebView.swift` übernehmen), lädt eine Viewer-Route der
  Web-App. Voraussetzung im Frontend (`cosmic-webapp-frontend`): Embed-Modus ohne Web-Chrome und Übergabe des Tokens
  (z. B. per `postMessage`/injiziertem Skript, nicht in der URL). Frontend-Teil vor der App umsetzen.
- `RoomDetailView.swift`: Viewer vollflächig, gläserne Toolbar, Infokarte, "Neu aufnehmen".

**Phase 5 – Scan-Ablauf**
- Raum-Karte (Name, Stockwerk, Checkliste) als Sheet vor `CosmicRoomCaptureView`.
- Steuerelemente in `Packages/CosmicCapture/Sources/CosmicCapture/FullGuidance/Support/GlassControlBackground.swift`,
  `FullGuidance/Screens/FullLiveCaptureView.swift`, `Screens/CaptureFlow/*` auf `glassEffect`/`GlassEffectContainer`
  umstellen. Capture-Pipeline und Bundle-Format bleiben unangetastet.

**Phase 6 – Login, Profil, Icon, Aufräumen**
- `LoginView.swift` neu, `ProfileView.swift` als Sheet. App-Icon mit Icon Composer (Asset kommt vom Nutzer/Designer).
- Einheitliche Sprache im App-Rahmen (offener Punkt unten). Alte RoomPlan-Dateien bleiben bis zum bestätigten
  echten Upload (bestehende Regel).

## Offene Punkte
- Logo ist noch nicht festgelegt (Akzent Silber ist entschieden, Sprache Englisch ist entschieden).

## Verifikation
- In dieser Cloud-Umgebung (Linux) gibt es kein Xcode: Builds und Tests laufen auf einem Mac mit Xcode 26.
- `xcodebuild -scheme CosmicCapture -destination 'platform=iOS Simulator,name=iPhone 17' test` in `Packages/CosmicCapture`
  (alle bisherigen 255 Tests grün), App-Build für Simulator und Gerät.
- SwiftUI-Previews für jeden neuen Screen (leer, lädt, Fehler, mit Daten).
- Auf dem iPhone: Login → Space wechseln → Raum scannen → Upload mit Bottom Accessory → Raum im Viewer öffnen;
  dazu Reduce Transparency, Increase Contrast, große Dynamic-Type-Stufen und VoiceOver prüfen.
- Phase 0: Prototyp im Browser auf Handybreite durchklicken.
