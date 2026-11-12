import CoreMedia

/// Where a frame came from. The whole point of the lab is that downstream code
/// (preview, inspector, detector) does not know this — it only sees FramePacket.
enum FrameSourceKind: String {
    case liveCamera   = "live"
    case videoFile    = "video"
    case injectedVCam = "vcam"
}

struct FramePacket {
    let sampleBuffer: CMSampleBuffer
    let kind: FrameSourceKind
    /// CACurrentMediaTime() at the moment the packet was produced — used for wall-clock FPS.
    let receivedHostTime: CFTimeInterval
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
