// LoginView.swift
// Email + password login screen.

import SwiftUI

struct LoginView: View {

    @StateObject private var viewModel = AuthViewModel()

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo / Title
            VStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(.primary)
                Text("Cosmic")
                    .font(.largeTitle.bold())
                Text("Scan. Capture. Visualize.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Form
            VStack(spacing: 16) {
                TextField("E-Mail", text: $viewModel.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                SecureField("Passwort", text: $viewModel.password)
                    .textContentType(.password)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await viewModel.login() }
                } label: {
                    Group {
                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Einloggen")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isLoading)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding()
    }
}

#Preview {
    LoginView()
}
