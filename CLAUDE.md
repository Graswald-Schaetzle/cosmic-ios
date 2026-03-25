# Cosmic iOS – Produkt-Kontext für AI Agents

## Was ist Cosmic?

Cosmic ist eine **Spatial-Data-Plattform für wohnbezogene Services**.

Der Kern: Ein User scannt einmalig sein Zuhause / Gebäudeinneres mit dem iPhone.
Daraus entsteht ein strukturiertes 3D-Modell mit Objekt- und Flächenerkennung –
was wo steht, wie groß Räume sind, Wandflächen, Deckenhöhen etc.

Dieses Modell ist die **dauerhafte Datenbasis**, auf der beliebige Services aufgebaut werden.

---

## Rolle der iOS App

Die iOS App ist der **Einstiegspunkt der gesamten Plattform** – ohne Scan kein Service.

Sie ist verantwortlich für:
1. **Erfassung**: LiDAR-gestützter 3D-Scan der Räumlichkeiten (RoomPlan / ARKit)
2. **On-Device-Verarbeitung**: 3D-Modell wird direkt auf dem iPhone generiert (kein Cloud-Upload für die Rekonstruktion nötig)
3. **Export**: Fertiges Modell als `.usdz`-Datei
4. **Upload**: Direkt ans cosmic-backend → Supabase Storage / GCS
5. **Verknüpfung**: Backend legt einen "Space"-Eintrag in der DB an mit Remote-URL → Web-App kann das Modell anzeigen

---

## Zwei 3D-Pipelines

| | On-Device (iOS App) | Cloud-Pipeline (separates Repo) |
|---|---|---|
| Gerät | iPhone mit LiDAR | Alle Geräte (Fallback) |
| Technologie | RoomPlan / ARKit LiDAR | Gaussian Splatting / Photogrammetry |
| Output | `.usdz` lokal | 3D-Modell via Backend |
| Vorteil | Schnell, offline, präzise | Geräteunabhängig |

---

## Was mit dem Modell passiert (Downstream)

Einmal erfasst, ermöglicht das Modell u.a.:

- **KI-gestützte Angebote** (z.B. Maler, Handwerker): KI liest Raumdaten direkt aus der DB
  (Wandflächen, Raummaße etc.) und fragt den User nur noch das, was fehlt (Wunschfarbe, Termin).
- **Virtuelle Visualisierung**: Möbel, Farben, Teppiche, Objekte im 3D-Modell platzieren
  und vorab visualisieren – der User sieht, was er kauft und wie es wirkt.
- **Wunschmarkierungen im 3D-Modell**: z.B. Wände direkt im Modell für einen Auftrag markieren.
- **Alle erdenklichen wohnbezogenen Services** – das Modell ist die universelle Datenbasis.

**Kernwert**: Der User muss Rauminfos nur einmal erfassen. Alle Services danach
greifen auf dieselbe Datenbasis zu – kein wiederholtes Ausmessen, Fotos schicken, erklären.

---

## Gesamtarchitektur (Überblick)

```
iOS App (dieser Repo)
  └── LiDAR Scan → .usdz → Upload
          ↓
cosmic-backend (Node.js / Supabase)
  └── Space-Eintrag in DB + Datei in GCS/Supabase Storage
          ↓
cosmic-webapp-frontend (React + Matterport SDK)
  └── 3D-Viewer, Service-Buchung, KI-Chat, Visualisierung
```

---

## Technische Rahmenbedingungen

- Deployment Target: **iOS 17.0** (SwiftData + RoomPlan)
- Architektur: **MVVM** (SwiftUI, kein Storyboard)
- Async: **async/await** (kein Completion Handler)
- Persistenz lokal: **SwiftData**
- Backend: REST API via `cosmic-backend`
- Auth: Supabase Auth / JWT (Token im Keychain)

Für detaillierte Coding-Regeln: siehe `agent-rules.md` im selben Verzeichnis.
