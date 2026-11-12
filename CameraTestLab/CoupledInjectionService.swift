import AVFoundation
import QuartzCore

/// Runs a **real** `AVCaptureSession` and an **injected video** source at the
/// same time, inside this app, to reproduce the single property an eKYC detector
/// must catch: the camera is genuinely live — the system privacy indicator (green
/// dot) is on and a real capture session is running, so any "is the camera
/// active?" check passes — yet the frames that reach the verification pipeline are
/// a replayed clip, not the live sensor.
///
/// This is still **in-process only**: it registers no system camera device and
/// touches no other app. It exists so `VCamDetectionService` can be exercised
/// against exactly this scenario, which the mutually-exclusive source tabs cannot
/// produce (there the real session is off, so there is no green dot to begin with).
///
/// Two modes map to the two demo cases:
///   - `.showVideo`             — green dot on; preview AND verified buffer are the video.
///   - `.showCameraBufferVideo` — green dot on; preview shows the live camera, but
///                                the verified buffer handed downstream is the video.
final class CoupledInjectionService: NSObject, FrameSource {

    enum Mode {
        /// Camera genuinely running (green dot), but you see — and the detector
        /// sees — the injected video.
        case showVideo
        /// Camera genuinely running (green dot) and shown on screen, while the
        /// buffer the detector evaluates is the injected video.
        case showCameraBufferVideo
    }

    let kind: FrameSourceKind = .injectedVCam
    weak var delegate: FrameSourceDelegate?

    private let mode: Mode
    private let camera = CameraCaptureService()
    private let injector: FrameSource
    private let lock = NSLock()
    private var latestCameraBuffer: CMSampleBuffer?

    /// - Parameters:
    ///   - injector: the in-app injected source (weak `VideoFixtureService` or
    ///               realistic `VCamInjectionService`) whose frames become the
    ///               verified buffer.
    ///   - mode: which of the two demo scenarios to run.
    init(injector: FrameSource, mode: Mode) {
        self.injector = injector
        self.mode = mode
        super.init()
    }

    func start() {
        // This combiner is the delegate of both sub-sources; it re-emits a single
        // combined packet to its own delegate (the view controller).
        camera.delegate = self
        injector.delegate = self
        camera.start()     // lights the green indicator; a genuine capture session is live.
        injector.start()   // the replayed clip that becomes the verified buffer.
    }

    func stop() {
        camera.stop()
        injector.stop()
        lock.lock(); latestCameraBuffer = nil; lock.unlock()
    }
}

extension CoupledInjectionService: FrameSourceDelegate {

    func frameSource(_ source: FrameSource, didOutput packet: FramePacket) {
        if source === camera {
            // Real sensor frames. The camera runs purely so the privacy indicator
            // is on and a real session exists; we keep the newest frame to show in
            // `.showCameraBufferVideo`, and otherwise drop it.
            lock.lock(); latestCameraBuffer = packet.sampleBuffer; lock.unlock()
            return
        }

        // Injector frame → this is the buffer the pipeline verifies.
        let previewBuffer: CMSampleBuffer?
        switch mode {
        case .showVideo:
            previewBuffer = nil                       // preview shows the video itself.
        case .showCameraBufferVideo:
            lock.lock(); previewBuffer = latestCameraBuffer; lock.unlock()
        }

        delegate?.frameSource(self, didOutput: FramePacket(
            sampleBuffer: packet.sampleBuffer,        // video = what the detector verifies.
            kind: .injectedVCam,
            receivedHostTime: packet.receivedHostTime,
            previewOverride: previewBuffer))          // live camera = what the human sees (mode 2).
    }

    func frameSource(_ source: FrameSource, didFailWith error: Error) {
        delegate?.frameSource(self, didFailWith: error)
    }
}
