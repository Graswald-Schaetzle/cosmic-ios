import SwiftUI
import ARKit

struct ARMeshViewRepresentable: UIViewRepresentable {
    let arView: ARSCNView
    
    func makeUIView(context: Context) -> ARSCNView {
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct ARMeshScannerView: View {
    @StateObject private var scanner = ARMeshScannerService.shared
    
    var body: some View {
        ZStack {
            // Die AR Ansicht mit dem generierten LiDAR Gitter
            ARMeshViewRepresentable(arView: scanner.sceneView)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                Spacer()
                
                if let url = scanner.exportUrl {
                    VStack {
                        Text("✅ Fotorealistisches 3D-Modell gespeichert!")
                            .font(.headline)
                        Text(url.lastPathComponent)
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.green.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding(.bottom, 20)
                }
                
                Button(action: {
                    if scanner.isScanning {
                        scanner.stopAndExport()
                    } else {
                        scanner.start()
                    }
                }) {
                    Text(scanner.isScanning ? "Scan beenden & Exportieren" : "Live-Mesh Scan Starten")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(scanner.isScanning ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(15)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            scanner.start()
        }
        .onDisappear {
            scanner.sceneView.session.pause()
        }
    }
}
