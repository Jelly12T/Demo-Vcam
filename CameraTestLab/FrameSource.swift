import CoreMedia

/// Where a frame came from. The whole point of the lab is that downstream code
/// (preview, inspector, detector) does not know this — it only sees FramePacket.
enum FrameSourceKind: String {
    case liveCamera   = "live"
    case videoFile    = "video"
    case injectedVCam = "vcam"
}

struct FramePacket {
    /// The buffer the pipeline *verifies* — what the inspector and detector see.
    let sampleBuffer: CMSampleBuffer
    let kind: FrameSourceKind
    /// CACurrentMediaTime() at the moment the packet was produced — used for wall-clock FPS.
    let receivedHostTime: CFTimeInterval
    /// Optional buffer to *display* instead of `sampleBuffer`. When set, the human
    /// watching the preview sees this while the detector still evaluates
    /// `sampleBuffer`. Used by the coupled demo to show the live camera on screen
    /// while the verified buffer is a replayed clip. `nil` ⇒ preview shows `sampleBuffer`.
    let previewOverride: CMSampleBuffer?

    init(sampleBuffer: CMSampleBuffer,
         kind: FrameSourceKind,
         receivedHostTime: CFTimeInterval,
         previewOverride: CMSampleBuffer? = nil) {
        self.sampleBuffer = sampleBuffer
        self.kind = kind
        self.receivedHostTime = receivedHostTime
        self.previewOverride = previewOverride
    }
}

protocol FrameSourceDelegate: AnyObject {
    func frameSource(_ source: FrameSource, didOutput packet: FramePacket)
    func frameSource(_ source: FrameSource, didFailWith error: Error)
}

protocol FrameSource: AnyObject {
    var kind: FrameSourceKind { get }
    var delegate: FrameSourceDelegate? { get set }
    func start()
    func stop()
}

enum LabError: LocalizedError {
    case cameraUnavailable
    case cameraAccessDenied
    case outputUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:   return "No capture device available (expected on Simulator)."
        case .cameraAccessDenied:  return "Camera access denied. Enable it in Settings."
        case .outputUnavailable:   return "Could not attach video data output."
        }
    }
}
