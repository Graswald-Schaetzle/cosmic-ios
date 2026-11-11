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

/// The one dominant action on a screen.
struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.black)
            // minHeight, not height: the label has to be free to grow with Dynamic Type.
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 20)
            .background(Color.white, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A quieter action that must not compete with the primary one.
struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.foreground)
            .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget)
            .padding(.horizontal, 20)
            .background(Theme.muted, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

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

/// Translucent circular chrome for buttons drawn over the camera feed, with an
/// opaque fallback under Reduce Transparency and Increase Contrast.
struct CameraChromeBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency || contrast == .increased {
            Capsule()
                .fill(Color.black.opacity(0.78))
                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
        } else {
            Capsule().fill(.ultraThinMaterial.opacity(0.9))
                .overlay(Capsule().fill(.black.opacity(0.25)))
        }
    }
}
