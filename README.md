# Camera Test Lab

UIKit + AVFoundation test bench (iOS 17+) for comparing a **live camera feed**
against an **in-app injected video feed**, inspecting the raw frames, and
running a **VCam detection module** that distinguishes the two.

## Scope

This is an **in-app** lab. The "virtual camera" here is a video file replayed
into the app's own pipeline — exactly the controlled test source a defender
needs. It does **not** register a system-level camera device and does **not**
inject into other apps; that requires jailbreak / process hooking and is the
attack class an eKYC system defends against, not something a normal iOS app can
or should do. The detector is the defensive piece; the injected source exists to
validate it.

## Structure

```
CameraTestLab/
├── CameraTestLab.xcodeproj/
├── CameraTestLab/
│   ├── AppDelegate.swift
│   ├── SceneDelegate.swift
│   ├── CameraLabViewController.swift   # UI: source switch, preview, FPS, inspector, detection, logs
│   ├── PreviewView.swift               # AVSampleBufferDisplayLayer — renders both sources uniformly
│   ├── FrameSource.swift               # protocol + FramePacket, the key abstraction
│   ├── CameraCaptureService.swift      # live camera (AVCaptureSession, intrinsics enabled)
│   ├── VideoFixtureService.swift       # WEAK injected video (BGRA, no intrinsics, PTS resets) — easy to flag
│   ├── VCamInjectionService.swift      # REALISTIC VCam reproduction (420v, forged intrinsics, monotonic PTS)
│   ├── FrameInspector.swift            # pixel format, resolution, PTS, intrinsics, attachments
│   ├── VCamDetectionService.swift      # defensive detector (replace with your production module)
│   ├── TestLog.swift                   # log entry model
│   └── Info.plist
├── project.yml                         # XcodeGen fallback
└── README.md
```

## Build & run

1. Open `CameraTestLab.xcodeproj` in Xcode 15+.
2. Select the `CameraTestLab` target → Signing & Capabilities → set your Team and
   change the bundle id from `com.example.CameraTestLab`.
3. Run on a **physical device** for the live camera (the Simulator has no camera;
   the Video Source path still works there).

If the project ever fails to open, regenerate it with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
brew install xcodegen && xcodegen generate
```

## Using it

- **Live Camera / Video Source / VCam** segmented control switches the active
  source. *Video Source* is a deliberately weak stand-in (BGRA, no intrinsics,
  looping PTS) the naive detector flags instantly. *VCam* reproduces a real
  attachment-preserving injector (iPhone-VCAM-style): it emits sensor-format
  `420v`, attaches a forged camera-intrinsic matrix, and keeps a monotonic PTS,
  so it **defeats all three client-side heuristics** — which is the whole point,
  it shows why frame-content / liveness / jailbreak-integrity signals are needed.
  Both injection tabs replay the clip chosen with **Choose Video…**.
- **Choose Video…** picks a clip from Photos or Files to inject.
- **Camera Preview + FPS** render whatever source is active (wall-clock FPS).
- **Frame Inspector** shows the current pixel buffer's format, resolution,
  planes, bytes-per-row, presentation timestamp, camera-intrinsics flag and
  sample attachment keys.
- **Detection** shows the verdict (Live sensor / Uncertain / Injected), a score
  and the reasons behind it.
- **Log Snapshot** records the current frame+verdict; **Export Logs** shares them.

Expected behaviour: the live front camera reads as *Live sensor*; the weak
*Video Source* reads as *Injected / VCam*; the realistic *VCam* source reads as
*Live sensor* too — a **false negative** that demonstrates the naive heuristics
are necessary-not-sufficient and motivates the stronger signals below.

## Extending

- Replace `VCamDetectionService.evaluate(_:)` with your real detector; the lab
  only depends on its `DetectionResult` interface.
- Add sources by conforming to `FrameSource` (e.g. an `AVAssetReader` replay with
  exact frame stepping, or a depth-enabled capture).

## Note for eKYC use

The client-side signals here (intrinsics, pixel format, timeline resets) are
**necessary-not-sufficient** and individually bypassable. Treat them as one layer
behind on-device liveness (incl. `AVDepthData` on TrueDepth) and server-side
verification. Do not gate identity decisions on client signals alone.
