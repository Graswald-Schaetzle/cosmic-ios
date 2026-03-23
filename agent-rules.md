# AI Agent Rules for Cosmic-iOS

This repository contains the Native iOS (SwiftUI) app for the Cosmic project. It is heavily focused on capturing high-quality video and AR/LiDAR data for 3D reconstruction (Gaussian Splatting / Photogrammetry).

## 1. Architecture
- **Framework**: Native Swift / SwiftUI.
- **Pattern**: MVVM (Model-View-ViewModel) - Keep Views thin, move logic to ViewModels.
- **Folder Structure Concept**:
  - `Views/`: SwiftUI Views (e.g., `CameraCaptureView.swift`, `UploadStatusView.swift`)
  - `ViewModels/`: Presentation logic and state management.
  - `Services/`: Core business logic that should be isolated.
    - `CameraCaptureService.swift`: Encapsulates `AVCaptureSession`.
    - `ARTrackingService.swift`: Encapsulates `ARSession` / `RoomPlan`.
    - `UploadService.swift`: Handles the 3-step upload flow to `cosmic-backend`.
  - `Models/`: Data structures representing API responses and internal app state.

## 2. Core Features & Constraints
### On-Device 3D Scanning (RoomPlan / ARKit)
- The app must use native Apple Frameworks (`RoomPlan` or `ARKit LiDAR Mesh`) to generate a full 3D model of a room directly on the device.
- Bypasses traditional cloud photogrammetry entirely for LiDAR-equipped devices.
- The user interface must embed the native scanning views (e.g. `RoomCaptureView`) smoothly into SwiftUI.

### Export & Direct Upload Flow
1. **Export**: Process the completed scan into a `.usdz` or `.glb` 3D model file directly on the iOS device.
2. **Direct Upload**: Bypass the heavy 3D-Gaussian-Splatting API. Instead, upload the finished 3D model file straight to the backend's storage bucket (e.g. Supabase Storage / GCS via normal document upload flows).
3. **Save Reference**: Ensure the web-app database associates the uploaded model file with the user/room, so `<model-viewer>` can display it on the web.

## 3. General Code Guidelines for AI Agents
- **Do not use Storyboards**. Everything must be built programmatically with SwiftUI.
- **Permissions**: Make sure to add the appropriate usage descriptions (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`) to `Info.plist` when adding camera/AR features.
- All asynchronous code should use modern Swift concurrency (`async`/`await`), avoiding completion handlers where possible.
- Provide clear, understandable states and error messages to the user during capture and upload.
