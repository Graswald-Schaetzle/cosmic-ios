import SwiftUI
import CosmicCapture

/// Profile sheet behind the avatar: the spaces and sign-out.
/// Phase 6 of docs/ios-redesign-plan.md adds account details and settings.
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(CosmicDesign.secondaryText)
                        Text("My account")
                            .font(.headline)
                    }
                    .padding(.vertical, 4)
                }

                Section("Spaces") {
                    if model.spaces.isEmpty {
                        Text(model.isLoadingSpaces ? "Loading…" : "No spaces")
                            .foregroundStyle(CosmicDesign.secondaryText)
                    }
                    ForEach(model.spaces) { space in
                        Button {
                            model.selectedSpaceID = space.spaceId
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(space.name)
                                        .foregroundStyle(.primary)
                                    Text(space.roomSummary)
                                        .font(.caption)
                                        .foregroundStyle(CosmicDesign.secondaryText)
                                }
                                Spacer()
                                if space.spaceId == model.selectedSpaceID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(CosmicDesign.accent)
                                }
                            }
                        }
                        .accessibilityAddTraits(space.spaceId == model.selectedSpaceID ? .isSelected : [])
                    }
                }

                Section {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        isConfirmingSignOut = true
                    }
                    .foregroundStyle(CosmicDesign.destructive)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
            .confirmationDialog("Sign out of Cosmic?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    model.selectedSpaceID = nil
                    AuthService.shared.signOut()
                }
            } message: {
                Text("Captures stay on this iPhone.")
            }
        }
        .presentationDetents([.medium, .large])
    }
}
