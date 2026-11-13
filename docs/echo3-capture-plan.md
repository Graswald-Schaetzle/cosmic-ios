# Plan: Raum-für-Raum-Capture mit SpAItial Echo-3

Stand: 11.11.2026. Umgesetzt ist Schritt 3 (iOS, ein Raum) bis zum lokal gespeicherten Capture
mit LiDAR-Daten, siehe "Umsetzungsstand". Alles andere ist offen. Dieses Dokument ist die Übergabe aus der
Planungs-Session, damit eine neue (lokale) Session ohne Vorwissen weiterarbeiten kann.

## Ziel

Die iOS-App nimmt eine Wohnung Raum für Raum auf. Jeder Raum wird als eigenes Capture an die
Echo-3-API von SpAItial geschickt, die daraus einen Gaussian Splat in echtem Maßstab berechnet.
Das Ergebnis wird in Cosmic importiert und im Splat-Viewer der Web-App angezeigt. Parallel
zeichnet die App LiDAR-Daten auf, die Echo-3 nicht annimmt, die wir aber selbst brauchen.

## Quellen

- API-Vertrag (maßgeblich): https://docs.spaitial.ai/api/capture-worlds
- Echo-3-Ankündigung: https://spaitial.ai/blog/echo-3-release
- Aufnahme-Tipps: https://spaitial.ai/blog/capture-guide
- Open-Source-Prototyp (MIT-0, darf frei übernommen werden):
  https://github.com/spaitial-ai/spaitial-capture-prototype
  Wichtig dort: `docs/bundle-format.md`, `docs/coordinate-conventions.md`,
  `docs/porting-guide.md`, `docs/guidance-setups.md`.

## Was die Echo-3-API verlangt

Basis-URL `https://api.spaitial.ai`, Authentifizierung per `Authorization: Bearer <API-Key>`.

| Endpunkt | Zweck |
| --- | --- |
| `GET /v1/captures/process-quote?model=echo-3&frame_count=N` | Preis und Dauer, kostenlos |
| `POST /v1/worlds` | Capture einreichen, Antwort `202` mit `request_id` |
| `GET /v1/worlds/requests/{request_id}/status` | Fortschritt |
| `GET /v1/worlds/requests/{request_id}/splat` | Splat herunterladen |

Request-Body für `POST /v1/worlds`:

```json
{
  "model": "echo-3",
  "input": {
    "type": "capture_bundle",
    "zip": { "type": "url", "zip_url": "https://..." }
  },
  "webhook": { "url": "https://.../spaitial" },
  "output_format": "spz"
}
```

- Die ZIP-URL muss per einfachem HTTPS-GET lesbar sein, Range-Requests unterstützen und
  2 Stunden gültig und unverändert bleiben (signierte Storage-URL).
- Webhooks: `world.completed` und `world.failed`.
- Kosten: 900 Credits pro Capture plus 1 Credit pro Frame. Fehlgeschlagene Jobs kosten nichts.
- Dauer: laut Doku 30 Minuten bis 2 Stunden; die Preisabfrage nannte für 600 Frames ca. 31 Minuten.
- Ausgabe: `spz` (Standard), `sog` oder `ply`, dazu ein Grundriss-Bild (`floorplan`).
  Ein Kollisions-Mesh liefert die API laut Doku nicht.

### Capture-ZIP

```
capture.zip
├── images/Image_000001.jpg ...        (lückenlos nummeriert, ab 1)
└── cameras/
    ├── per_frame_intrinsics.json      (Pflicht)
    └── camera_trajectory.json         (empfohlen)
```

- 1 bis 5.000 Frames, höchstens 64 MiB pro Datei, 8 GiB gesamt, nur stored oder deflate.
- JPEG in nativer Sensorgröße 1920×1440, nicht skalieren, nicht drehen, EXIF-Orientation
  fehlt oder ist 1. Qualität 0,85.
- EXIF `DateTimeOriginal`, `SubSecTimeOriginal`, `OffsetTimeOriginal` in jedem Bild, streng
  aufsteigend. Auf iOS `ARFrame.exifData` unverändert durchreichen.
- Intrinsics: `frame_count`, `width_px`, `height_px` und die Arrays `fx_px`, `fy_px`, `cx_px`,
  `cy_px` aus `ARFrame.camera.intrinsics`.
- Posen: Array aus 4×4-Matrizen, zeilenweise, OpenCV `camera_from_world` in Metern:
  `M = diag(1, -1, -1, 1) · inverse(ARFrame.camera.transform)`.
- Alle Posen eines Bundles stammen aus derselben ARKit-Welt (`worldAlignment = .gravity`).
- Eine Haltung (Hoch- oder Querformat) für den ganzen Scan.

### Welche Frames gespeichert werden

Keyframes nach Bewegung, kein Video und kein Timer:

- erst nach 0,5 s stabilem Tracking; nach jeder Unterbrechung neu warten,
- Abstand mindestens 0,12 s und 7 cm oder 10° Bewegung; nach 0,35 s genügen 1 cm oder 1,5°,
- Frames mit vorhergesagter Bewegungsunschärfe über 64 px verwerfen,
- nie bei eingeschränktem Tracking.

Diese Regeln gehören zum Echo-3-Vertrag und stecken fertig im Prototyp
(`ios/Capture/ContinuousScanSampler.swift`, `CaptureTrackingSettleGate.swift`,
`CaptureFrameQualityGate.swift`).

## Stand der iOS-App heute

- `ARMeshScannerView` + `ScanViewModel`: Scan mit RoomPlan, Export als `.usdz`, Upload als Space.
- `ARMeshVisualizationView`: Drahtgitter-Overlay aus den LiDAR-Mesh-Ankern.
- `LiDARCaptureService`: speichert JPEG-Frames und `transforms.json` im Nerfstudio-Format
  (3 cm / 3° Abstand, jedes 15. Frame). Dieses Format passt nicht zu Echo-3.
- `ScanPackager`: ZIP ohne Kompression, wiederverwendbar.
- `ReconstructionJobService`: lädt das ZIP in die alte RunPod/GCS-Pipeline, die nicht mehr
  verwendet wird.
- Deployment Target iOS 17, Swift 5. Der Prototyp verlangt iOS 18 und Swift 6.

## Ablauf in der App

1. **Space anlegen**: Name, Stockwerke, optional eine Raumliste vorab.
2. **Raum-Karte vor jedem Capture**: Raumname, Stockwerk und Checkliste (Licht an, Tür zu,
   niemand im Raum, eine Haltung beibehalten).
3. **Live-Scan**: Kamerabild mit LiDAR-Netz, das erfasste Flächen einfärbt. Immer nur ein
   Hinweis gleichzeitig ("Langsamer", "Decke fehlt noch"), Frame-Zähler, Fortschritt für
   Wände, Decke und Boden.
4. **Raum-Review**: 3D-Vorschau mit Lücken, dann "Weiter scannen" oder "Raum fertig".
5. **Nächste Tür markieren**: Nach dem Review fragt die App "Wo geht es weiter?". Der Nutzer
   richtet das Handy auf die Tür, durch die er als Nächstes geht, und tippt sie an.
6. **Nächster Raum**: durchgehen, Tür schließen, neues Capture starten. Die App schlägt die
   Tür hinter dem Nutzer als dieselbe Tür vor; er bestätigt nur.
7. **Übersicht**: alle Räume mit Status (aufgenommen, lädt hoch, wird berechnet, fertig),
   Upload im Hintergrund, Push-Nachricht bei Fertigstellung.

### Festgelegte Entscheidungen

- **Ein Capture pro Raum**, alle anderen Türen bleiben geschlossen.
- **Tür erst schließen, dann aufnehmen.** SpAItial warnt davor, Türen während des Scans zu
  bewegen (Artefakte). Das Capture beginnt deshalb erst im Raum bei geschlossener Tür, nicht
  auf der Schwelle.
- **Keine manuelle Markierung von Fenstern, Spiegeln, Türen als Objekte.** Das übernimmt
  später die KI-Objekterkennung. Manuell markiert wird nur die Tür zum nächsten Raum.
- **Der API-Key liegt nur im Backend**, nie in der App.
- **Optik**: Glas-Look der Web-App (dunkle, halbtransparente Panels, große Rundungen,
  Raum-Chips in Orange `#FFA600`).

### Räume verknüpfen

- Beim Tür-Markieren speichert die App Position und Ausrichtung der Türöffnung (Raycast auf
  das LiDAR-Mesh) und die Kante "Raum A führt durch diese Tür zu Raum B".
- Die ARKit-Session läuft zwischen den Räumen weiter, speichert aber keine Frames. So liegen
  die Captures im selben Weltkoordinatensystem.
- Türposition, Wandrichtung und Schwerkraft legen die Lage zweier Räume zueinander eindeutig
  fest. Das Backend berechnet daraus die Lage jedes Raums im Space.
- Daraus entsteht ein Raum-Graph, der auch für Minimap und Navigation nutzbar ist.

## LiDAR parallel aufzeichnen

Echo-3 nimmt keine Tiefendaten an. Die App speichert sie trotzdem neben dem Bundle (nicht im
ZIP für SpAItial):

- LiDAR-Mesh je Raum: Grundlage für `collision.glb`, das der Web-Viewer braucht.
- Türanker und Mesh: Ausrichtung der Räume zueinander.
- Später: Maße und Objekterkennung.

ARKit-Konfiguration wie in der "Full"-Variante des Prototyps: `sceneReconstruction`
(`.meshWithClassification`, sonst `.mesh`) und `.sceneDepth`, Videoformat 1920×1440.

## Technik

### iOS

- Capture-Kern aus dem Prototyp übernehmen (`ios/Capture/`, `ios/Storage/`), dazu
  `ios/FullGuidance/` für Netz, Lücken-Coaching und Review. Die Liste der nötigen Dateien steht
  in `docs/porting-guide.md` des Prototyps, Option B.
- Die Tests für Geometrie, Sampler, Settle-Gate und Writer mit übernehmen.
- Speicher um LiDAR-Mesh, Türanker und Raum-Metadaten erweitern.
- Deployment Target auf iOS 18 anheben (Vorschlag, noch nicht bestätigt).
- RoomPlan im neuen Scan zunächst weglassen; später parallel zuschalten, falls die Objekt- und
  Flächenerkennung weiter gebraucht wird.
- `LiDARCaptureService` und `ReconstructionJobService` werden durch den neuen Weg ersetzt.

### Backend (`cosmic-backend`)

- Umgebungsvariablen `SPAITIAL_API_KEY` und `SPAITIAL_WEBHOOK_SECRET`. Sie sind als
  GitHub-Secrets im Repo angelegt, aber noch nicht in `.github/workflows/deploy.yml`
  eingetragen.
- Ablauf: App lädt das ZIP in den privaten Supabase-Bucket `captures` (existiert, 1 GB pro
  Datei) → Backend erzeugt eine signierte URL und ruft `POST /v1/worlds` auf → Webhook oder
  Polling → `.spz`, Grundriss und Kollisions-Mesh in den Bucket `splats`.
- Migration: ein Capture hängt an einem Raum (heute ein Splat pro Space), dazu
  Türverknüpfungen und die Lage des Raums im Space.
- Vorhandene Bausteine: `scripts/import-splat-space.js` (Import mit automatischer Kalibrierung
  aus dem Kollisions-Mesh), `app/autoFrame.js`, `docs/space-coordinate-system.md`,
  `docs/minimap.md`.

### Web-Frontend

- Mehrere Raum-Splats in einem Space anzeigen. Heute lädt der Viewer genau einen Splat.

## Reihenfolge

1. **Test von Hand**: ein Raum mit dem unveränderten Prototyp (`CapturePrototypeFull`)
   aufnehmen, ZIP mit `tools/validate-bundle` prüfen, an Echo-3 schicken, Ergebnis in Cosmic
   importieren.
2. **Backend**: Echo-3-Anbindung mit Webhook und Migration.
3. **iOS, ein Raum**: neuer Scan mit LiDAR-Netz und Upload.
4. **iOS, mehrere Räume**: Raum-für-Raum-Ablauf, Stockwerke, Tür-Verknüpfung.
5. **Web-Viewer**: mehrere Raum-Splats pro Space.

## Umsetzungsstand

- **Schritt 3, iOS ein Raum** (Branch `feature/echo3-single-room-capture`): Der Prototyp
  (Stand `2d89e6f`, Full-Variante) liegt als lokales Paket in `Packages/CosmicCapture`.
  Ein Capture landet unter `Documents/Captures/<id>/` mit `bundle/` (Echo-3-Vertrag,
  unverändert) und `lidar/` (`mesh.glb` nach Klassifikation gruppiert, `depth/` und
  `confidence/` als PNG pro gespeichertem Frame, `metadata.json`). `lidar/` wird nie ins ZIP
  gepackt. Die Capture-Liste exportiert das ZIP über das Teilen-Menü; damit lässt sich
  Schritt 1 auch mit der Cosmic-App statt mit dem Prototyp durchführen.
- Geprüft: 255 Paket-Tests im Simulator, App-Build für Simulator und Gerät. **Nicht geprüft**:
  der Scan auf einem echten iPhone (Kamera, LiDAR-Netz, gespeichertes Mesh und Tiefe).
- Der Capture-Ablauf nutzt den Glas-Look der App (immer dunkel, halbtransparente Panels mit
  32 pt Rundung, weiße Kapsel-Buttons, Akzent `#FFA600`). Die Texte bleiben englisch.
- **Schritt 2, Backend**: Endpunkte `/room-captures` (Upload-URL, Start bei Echo-3, Webhook,
  Polling, Import des Splats) und Migration `20261111000001_room_captures.sql` sind
  geschrieben, die Migration ist auf Supabase angewendet. Beschreibung in
  `cosmic-backend/docs/room-captures.md`. Das Backend ist auf Cloud Run deployt. Noch kein
  echter Echo-3-Job gelaufen.
- **Upload aus der App**: `RoomCaptureUploadService` und die Capture-Liste laden ein Capture in
  den gewählten Space (Kostenabfrage und Bestätigung, ZIP und LiDAR-Mesh direkt in den Bucket
  `captures`, Start bei Echo-3, Statusabfrage alle 30 s bei offener Liste). Der Upload läuft
  im Vordergrund; Upload im Hintergrund und Push-Nachricht fehlen. Nur gebaut, **nicht mit
  einem echten Capture getestet**.
- Offen in Schritt 3: Test auf dem iPhone, danach Entfernen des alten RoomPlan-Scans.
- iOS 18 als Mindestversion ist bestätigt.

## Mehrere Räume im Viewer und Neuaufnahme einzelner Räume

Stand: Entscheidungen des Nutzers, Ergänzung zum Plan. Gilt für Backend, Frontend und iOS.

### Warum ein Splat pro Raum bei geschlossenen Türen

1. **Einzelne Räume neu aufnehmen.** Ändert sich in einem Raum etwas (Möbel, Farbe, Umbau), muss nur dieser
   Raum neu gefilmt werden, nicht der ganze Space.
2. **Kein veralteter Nachbarraum im Splat.** Bei geschlossenen Türen sieht ein Capture den Nachbarraum nicht.
   Bei offenen Türen steckt der Nachbarraum im alten Zustand mit im Splat, und die Räume wären nach einer
   Neuaufnahme eines einzelnen Raums nicht mehr synchron.
3. **Dateigröße und Ladezeit.** Kleinere Splats pro Raum bleiben unter den Capture-Grenzen (Frames, Dateigröße,
   Verarbeitungsdauer) und laden im Browser schneller. Gemessen ist das noch nicht.

Ein Streaming-Format für riesige Szenen (Nachladen von Teilen eines einzigen Splats) ist nicht nötig und wurde nicht
bewertet. Das Nachladen pro Raum liefert denselben Effekt und passt zur Neuaufnahme einzelner Räume.

### Verhalten im Web-Viewer

- Pro Space ist ein **Startraum festlegbar**. Ohne Festlegung gilt der Raum, in dem das **allererste Foto** des Spaces
  aufgenommen wurde (erstes Bild des ältesten Captures).
- Der Startraum lädt zuerst. Jeder weitere Raum lädt nach, sobald der Nutzer an der Tür bzw. Schwelle zum
  nächsten Raum steht oder ihn betritt. Nicht alle Räume auf einmal laden.
- Heute zeigt der Viewer (`SplatScene` mit `splatUrl`/`collisionUrl`) nur einen Splat und muss umgebaut werden.

### Räume zueinander ausrichten

**Variante A (bisheriger Plan):** Die ARKit-Session läuft zwischen den Räumen weiter, der Nutzer markiert die Tür
zum nächsten Raum (Raycast auf das LiDAR-Mesh), das Backend berechnet daraus die Lage der Räume.

**Variante B (Fallback und Ergänzung, Idee des Nutzers):** Die App führt den Nutzer über die Oberfläche:
1. Beim Verlassen markiert er die Tür, durch die er in den nächsten Raum geht.
2. Im nächsten Raum fordert ihn die App auf, **direkt hinter der Tür zu starten** (Tür schließen, dann aufnehmen).
3. Tür-Markierung und Startposition ergeben eine grobe Zuordnung, wo ein Raum endet und der nächste beginnt.
   Sie funktioniert auch dann, wenn das ARKit-Tracking beim Gang durch die Tür abreißt.

Wie genau diese grobe Lage in Splat-Koordinaten übersetzt werden kann, hängt weiter davon ab, in welchem
Koordinatensystem Echo-3 den Splat zurückgibt (offener Punkt unten). Die Feinausrichtung läuft bei Bedarf über das
LiDAR-Mesh und die Türanker.

## Offene Punkte

- **Koordinatensystem der Ausgabe**: Die Doku sagt nicht, ob Echo-3 den Splat im
  Koordinatensystem der eingereichten Posen zurückgibt. Schritt 1 muss das zeigen. Wenn nicht,
  werden die Räume über LiDAR-Mesh und Türanker ausgerichtet.
- **Antwortformate**: Die Antwort des Status-Endpunkts bei Erfolg und die Signatur der
  Webhooks stehen nicht in der Doku. Beim ersten echten Job mitschreiben.
- **Upload-Größe**: Ein Raum ergibt geschätzt 200 bis 600 MB. Die Organisation hat den
  Pro-Tarif, der Bucket `captures` erlaubt 1 GB pro Datei. Das globale Dateigrößen-Limit des
  Projekts (Supabase: Storage > Settings, Standard 50 MB) ist ungeprüft und muss mindestens
  1 GB betragen; die größte Datei bisher hat 13 MB.
- **Guthaben**: Am 11.11.2026 abends 7906 Credits. Ein Capture kostet 900 Credits plus
  1 Credit pro Frame.
- **Tracking zwischen Räumen**: Ob ARKit das Tracking beim Gang durch die Tür zuverlässig
  hält, muss mit zwei echten Räumen getestet werden.

## Lokal arbeiten

- Kamera und LiDAR laufen nur auf einem echten iPhone, nicht im Simulator. Unit-Tests laufen
  im Simulator.
- Xcode-Anbindung für Claude Code (ab Xcode 26.3, Befehl ungeprüft):
  `claude mcp add --transport stdio xcode -- xcrun mcpbridge`. Ohne sie über `xcodebuild`.
- Schlüssel lokal in `cosmic-backend/.env` unter denselben zwei Namen; nie einchecken.
