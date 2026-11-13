import SwiftUI

enum CaptureScreenLayoutPolicy {
    static let minimumColumnWidth: CGFloat = 280
    static let columnSpacing: CGFloat = 24
    static let readableColumnWidth: CGFloat = 620

    static func usesLandscapeColumns(
        availableSize: CGSize,
        isAccessibilitySize: Bool = false
    ) -> Bool {
        guard !isAccessibilitySize, availableSize.width > availableSize.height else {
            return false
        }
        return availableSize.width >= minimumColumnWidth * 2 + columnSpacing
    }
}

struct ScreenScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }
}

extension View {
    /// Centers a single column at a readable width; a no-op on phones.
    func readableColumn(
        maxWidth: CGFloat = CaptureScreenLayoutPolicy.readableColumnWidth
    ) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

/// The capture flow uses the shared Cosmic button styles (see `CosmicDesign.swift`).
typealias PrimaryActionButtonStyle = CosmicPrimaryButtonStyle
typealias SecondaryActionButtonStyle = CosmicSecondaryButtonStyle

struct LoadingButtonLabel: View {
    let title: String
    let loadingTitle: String
    let isLoading: Bool
    var progressTint = Color.black

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView().tint(progressTint)
            }
            Text(isLoading ? loadingTitle : title)
        }
        .accessibilityLabel(isLoading ? loadingTitle : title)
    }
}

/// Focused text entry belongs in a sheet, not an alert.
struct CaptureRenameSheet: View {
    let onSave: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage: String?

    init(initialName: String, onSave: @escaping (String) -> String?) {
        _name = State(initialValue: initialName)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Scan name", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(save)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.destructive)
                }
            }
            .navigationTitle("Rename scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(trimmedName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if let error = onSave(trimmedName) {
            errorMessage = error
            return
        }
        dismiss()
    }
}

/// Preserves the complete thumbnail while filling differently shaped slots.
struct CaptureThumbnailImage: View {
    let image: Image

    var body: some View {
        Color.clear
            .overlay {
                image.resizable().scaledToFill().blur(radius: 12)
            }
            .overlay(Color.black.opacity(0.24))
            .overlay {
                image.resizable().scaledToFit()
            }
            .clipped()
    }
}

/// Liquid Glass behind controls drawn over the camera feed. Reduce
/// Transparency and Increase Contrast are handled by the system material.
struct CameraChromeBackground: View {
    var body: some View {
        Color.clear.glassEffect(.regular, in: Capsule())
    }
}
