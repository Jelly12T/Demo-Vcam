import AVFoundation
import QuartzCore
import simd

/// High-fidelity reproduction of a system-level virtual camera (e.g. iPhone-VCAM)
/// **inside this process**. Unlike `VideoFixtureService` — a deliberately weak
/// stand-in — this source forges the three client-side signals the naive detector
/// relies on, exactly the way an attachment-preserving jailbreak injector does:
///
///   1. Sensor pixel format — emits biplanar `420v` instead of BGRA.
///   2. Camera intrinsics   — attaches a synthetic 3×3 intrinsic matrix, so
///                            `hasCameraIntrinsics` reads `true`.
///   3. Monotonic timeline  — PTS is host-clock based and never resets on loop.
///
/// It still injects only into THIS app's own pipeline — it registers no system
/// camera device and touches no other process. The point is to give the defender
/// a realistic attack sample: run it and watch the naive heuristics score it as a
/// live sensor, which is why frame-content/liveness signals are needed.
final class VCamInjectionService: NSObject, FrameSource {

    let kind: FrameSourceKind = .injectedVCam
    weak var delegate: FrameSourceDelegate?

    private let player: AVPlayer
    private let item: AVPlayerItem
    private let videoOutput: AVPlayerItemVideoOutput
    private var displayLink: CADisplayLink?
    private var formatDescription: CMFormatDescription?
    private var startHostTime: CFTimeInterval?

    init(url: URL) {
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        // (1) Request the sensor-style biplanar format, not BGRA.
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        super.init()
        item.add(videoOutput)
    }

    func start() {
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(
            self, selector: #selector(loop),
            name: .AVPlayerItemDidPlayToEndTime, object: item)

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        player.play()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        player.pause()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func loop() {
        // Seek the media back, but DO NOT reset our PTS clock — the emitted
        // timeline stays monotonic across loops, defeating the replay-reset signal.
        player.seek(to: .zero)
        player.play()
    }

    @objc private func tick() {
        let hostTime = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: hostTime)
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        else { return }

        // (3) Monotonic, host-clock-based PTS that never goes backwards.
        if startHostTime == nil { startHostTime = hostTime }
        let elapsed = hostTime - (startHostTime ?? hostTime)
        let pts = CMTime(seconds: elapsed, preferredTimescale: 600)

        guard let sampleBuffer = makeSampleBuffer(pixelBuffer, pts: pts) else { return }
        attachForgedIntrinsics(to: sampleBuffer, pixelBuffer: pixelBuffer)

        delegate?.frameSource(self, didOutput: FramePacket(
            sampleBuffer: sampleBuffer,
            kind: .injectedVCam,
            receivedHostTime: hostTime))
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        // Rebuild the format description per frame is wasteful; cache while the
        // dimensions/format are stable (they are, for a single clip).
        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription)
        }
        guard let fd = formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    /// (2) Attach a plausible 3×3 camera intrinsic matrix, as a real capture
    /// connection would and as an attachment-preserving injector keeps. The naive
    /// detector only checks for the key's *presence*, which this satisfies.
    private func attachForgedIntrinsics(to sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) {
        let w = Float(CVPixelBufferGetWidth(pixelBuffer))
        let h = Float(CVPixelBufferGetHeight(pixelBuffer))
        let focal = w                       // ~ typical front-camera focal in pixels
        var k = matrix_float3x3(
            SIMD3<Float>(focal, 0,     0),
            SIMD3<Float>(0,     focal, 0),
            SIMD3<Float>(w / 2, h / 2, 1))  // column-major: principal point in 3rd column
        let data = withUnsafeBytes(of: &k) { Data($0) } as CFData
        CMSetAttachment(sampleBuffer,
                        key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                        value: data,
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
    }
}
