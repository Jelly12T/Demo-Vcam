import AVFoundation
import QuartzCore

/// Plays a user-chosen video (Photos/Files) and re-emits each frame as a
/// CMSampleBuffer into the same pipeline the live camera feeds. This is the
/// in-app "virtual camera" — frames carry no camera intrinsics, use a non-sensor
/// pixel format, and reset their timeline on loop, which the detector flags.
final class VideoFixtureService: NSObject, FrameSource {

    let kind: FrameSourceKind = .videoFile
    weak var delegate: FrameSourceDelegate?

    private let player: AVPlayer
    private let item: AVPlayerItem
    private let videoOutput: AVPlayerItemVideoOutput
    private var displayLink: CADisplayLink?
    private var formatDescription: CMFormatDescription?

    init(url: URL) {
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
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
        player.seek(to: .zero)
        player.play()
    }

    @objc private func tick() {
        let hostTime = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: hostTime)
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
              let sampleBuffer = makeSampleBuffer(pixelBuffer, pts: itemTime) else { return }

        delegate?.frameSource(self, didOutput: FramePacket(
            sampleBuffer: sampleBuffer,
            kind: .videoFile,
            receivedHostTime: hostTime))
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
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
}
