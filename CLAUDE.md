# Cosmic iOS – Produkt-Kontext für AI Agents

Antworte dem Nutzer immer auf Deutsch (Code, Commit-Messages und Bezeichner bleiben englisch).

## Was ist Cosmic?

Cosmic ist eine **Spatial-Data-Plattform für wohnbezogene Services**.

Der Kern: Ein User erfasst einmalig sein Zuhause mit dem iPhone. Daraus entsteht ein
3D-Raum (Gaussian Splat), der in der Web-App mit Aufgaben, Listen, Dokumenten, Tags und
weiteren Services verknüpft wird. Zentrales Domänenobjekt ist der **Space** mit Floors und Rooms.

Dieses Modell ist die **dauerhafte Datenbasis**, auf der beliebige Services aufgebaut werden:
KI-gestützte Angebote (Maler, Handwerker) aus Raumdaten, virtuelle Visualisierung von Möbeln und
Farben, Markierungen direkt im 3D-Modell. Der User erfasst Rauminfos nur einmal.

---

## Rolle der iOS App

Die iOS App ist der **Einstiegspunkt der gesamten Plattform** – ohne Aufnahme kein Service.

## Aktuelle Richtung: Raum-für-Raum-Capture mit SpAItial Echo-3

**Vor jeder Arbeit am Scan zuerst `docs/echo3-capture-plan.md` lesen.** Dort stehen Ablauf,
Bundle-Format, Entscheidungen, Reihenfolge und offene Punkte.

Kurzfassung:
- Die App nimmt jeden Raum als eigenes Capture auf (JPEG-Keyframes mit ARKit-Posen und
  Kalibrierung, als ZIP) und zeichnet parallel LiDAR-Mesh und Tiefe auf.
- Das Backend schickt das ZIP an die Echo-3-API von SpAItial und importiert den fertigen Splat
  (`.spz`) in den Space. Der API-Key liegt nur im Backend, nie in der App.
- Am Ende eines Raums markiert der User die Tür zum nächsten Raum und startet im nächsten Raum
  direkt hinter der Tür (Tür geschlossen); darüber werden die Räume später zusammengefügt.
  Warum ein Splat pro Raum und wie der Viewer die Räume nachlädt: siehe Plan, Abschnitt
  "Mehrere Räume im Viewer und Neuaufnahme einzelner Räume".
- Capture-Kern und LiDAR-Netz kommen aus dem Open-Source-Prototyp
  `spaitial-ai/spaitial-capture-prototype` (MIT-0).

## Stand im Code

Neu (Schritt 3 des Plans, ein Raum):

| Ort | Inhalt |
|---|---|
| `Packages/CosmicCapture/` | Lokales Swift-Paket (Swift 6, iOS 18) mit dem Capture-Kern und der Full-Guidance des Prototyps samt Tests. Cosmic-Erweiterungen in `Sources/CosmicCapture/Cosmic/`: LiDAR-Mesh (`lidar/mesh.glb`), Tiefe pro Frame (`lidar/depth/`), `CosmicCaptureStore`, `CosmicRoomCaptureView`. |
| `RoomCapturesView.swift` | Liste der lokalen Captures mit Upload in den gewählten Space (vorher Kostenabfrage), Status und ZIP-Export. |
| `RoomCaptureUploadService.swift` | Upload über `/room-captures` im Backend: Capture anmelden, ZIP und LiDAR-Mesh direkt in den Storage laden, Echo-3 starten, Status abfragen. Zustand pro Capture in `UserDefaults`. Noch nicht mit einem echten Capture getestet. |
| `CosmicHomeView.swift` | "Start Scan" öffnet `CosmicRoomCaptureView`, "History" die Capture-Liste. |

Paket-Tests: `xcodebuild -scheme CosmicCapture -destination 'platform=iOS Simulator,name=<iPhone>' test`
im Ordner `Packages/CosmicCapture`. Die Texte im Capture-Ablauf und in der Capture-Liste sind englisch (so entschieden).

Alt (nicht mehr aus der App erreichbar, wird entfernt, sobald der Upload mit einem echten Capture bestätigt ist):

| Datei | Inhalt | Zukunft |
|---|---|---|
| `ARMeshScannerView.swift`, `ScanViewModel.swift`, `ARTrackingService.swift` | Scan mit RoomPlan, Export `.usdz` | wird durch den neuen Capture-Ablauf ersetzt |
| `ARMeshVisualizationView.swift` | Drahtgitter-Overlay aus LiDAR-Mesh-Ankern | wird durch das Coverage-Netz des Prototyps ersetzt |
| `LiDARCaptureService.swift` | Frames + `transforms.json` (Nerfstudio) | falsches Format für Echo-3, wird ersetzt |
| `ScanPackager.swift` | ZIP ohne Kompression | wiederverwendbar |
| `ReconstructionJobService.swift` | Upload in die alte RunPod/GCS-Pipeline | nicht mehr verwenden |
| `SpatialUploadService.swift`, `SpatialScanModels.swift` | RoomPlan-Objekte und -Flächen ans Backend | bleibt vorerst |
| `CosmicHomeView.swift`, `MenuService.swift`, `SpaceService.swift` | natives Home-Menü und Spaces | bleibt |
| `MatterportWebView.swift` | Matterport-Ansicht | kein neuer Code dafür |

Der Quellcode liegt in `cosmic-ios/` (flach). Die Dateien unter `App/` sind ältere Kopien und
gehören nicht zum Xcode-Target.

**Nicht mehr verwenden**: die RunPod-3D-Pipeline und der Upload nach GCS. **Matterport wird
ersetzt**: kein neuer Code und keine neuen Features dafür.

---

## Gesamtarchitektur

```
iOS App (dieses Repo)
  └── Capture pro Raum (ZIP) + LiDAR-Mesh → Upload
          ↓
cosmic-backend (Node.js/Express auf Google Cloud Run, Supabase für DB und Storage)
  └── schickt das ZIP an SpAItial Echo-3, importiert .spz + collision.glb in den Space
          ↓
cosmic-webapp-frontend (React, Splat-Viewer mit three + @sparkjsdev/spark, auf Vercel)
  └── 3D-Viewer, Aufgaben, Dokumente, Tags, Minimap
```

- Repos in der GitHub-Organisation `Graswald-Schaetzle`: `cosmic-ios`, `cosmic-backend`,
  `cosmic-webapp-frontend`.
- Backend-URL: siehe `Config.swift` (`backendBaseURL`).
- Supabase Storage: Bucket `splats` (fertige Splats und Kollisions-Meshes), Bucket `captures`
  (privat, hochgeladene Capture-ZIPs).

---

## Technische Rahmenbedingungen

- Deployment Target: **iOS 18.0** (bestätigt am 11.11.2026). Das App-Target bleibt Swift 5;
  das Paket `Packages/CosmicCapture` ist Swift 6.
- Architektur: **MVVM** (SwiftUI, kein Storyboard)
- Async: **async/await** (kein Completion Handler)
- Persistenz lokal: **SwiftData**
- Backend: REST API via `cosmic-backend`
- Auth: Login über das Backend / Supabase, Token im Keychain
- Kamera und LiDAR laufen nur auf einem echten iPhone; im Simulator laufen nur Unit-Tests.

## Geheimnisse

Keine Keys, Passwörter oder Tokens in Dateien, Commits oder Chats schreiben. Der SpAItial-API-Key
und das Webhook-Secret liegen als `SPAITIAL_API_KEY` und `SPAITIAL_WEBHOOK_SECRET` in den
GitHub-Secrets von `cosmic-backend` und lokal in dessen `.env`.

Für detaillierte Coding-Regeln: siehe `agent-rules.md` im selben Verzeichnis. Die Abschnitte
dort zu RoomPlan-Export und direktem `.usdz`-Upload beschreiben den alten Weg; maßgeblich für
den Scan ist `docs/echo3-capture-plan.md`.
