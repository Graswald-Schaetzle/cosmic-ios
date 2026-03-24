import SwiftUI
import SwiftData

struct ScanHistoryView: View {
    @Query(sort: \ScanRecord.createdAt, order: .reverse) var scans: [ScanRecord]
    @Environment(\.modelContext) var modelContext

    var body: some View {
        NavigationStack {
            Group {
                if scans.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(scans) { scan in
                            NavigationLink(destination: ScanDetailView(scan: scan)) {
                                scanRow(scan: scan)
                            }
                        }
                        .onDelete(perform: deleteScans)
                    }
                }
            }
            .navigationTitle("Scan-Verlauf")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Noch keine Scans")
                .font(.title3.weight(.semibold))
            Text("Gehe zum Tab 'Scan', um deinen ersten Raum zu erfassen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Row

    private func scanRow(scan: ScanRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scan.name)
                .font(.headline)
            Text(formattedDate(scan.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
            uploadBadge(isUploaded: scan.isUploaded)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func uploadBadge(isUploaded: Bool) -> some View {
        if isUploaded {
            Label("Hochgeladen", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green, in: Capsule())
        } else {
            Label("Lokal", systemImage: "internaldrive")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
    }

    // MARK: - Delete

    private func deleteScans(at offsets: IndexSet) {
        for index in offsets {
            let scan = scans[index]
            // Lokale Datei löschen
            if let localURL = URL(string: scan.localFileURL) {
                try? FileManager.default.removeItem(at: localURL)
            }
            modelContext.delete(scan)
        }
    }

    // MARK: - Helpers

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: date)
    }
}

// MARK: - Detail View

struct ScanDetailView: View {
    let scan: ScanRecord

    var body: some View {
        List {
            Section("Informationen") {
                LabeledContent("Name", value: scan.name)
                LabeledContent("Erstellt", value: formattedDate(scan.createdAt))
                LabeledContent("Status", value: scan.isUploaded ? "Hochgeladen" : "Lokal")
            }

            if let remoteURLString = scan.remoteURL, let remoteURL = URL(string: remoteURLString) {
                Section("Online-Modell") {
                    Link("Im Browser öffnen", destination: remoteURL)
                }
            }

            Section("Lokale Datei") {
                if let localURL = URL(string: scan.localFileURL),
                   FileManager.default.fileExists(atPath: localURL.path) {
                    ShareLink(item: localURL) {
                        Label("USDZ-Datei teilen", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text("Datei nicht mehr verfügbar")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: date)
    }
}
