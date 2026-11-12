import AVFoundation
import QuartzCore

/// Live camera source. Front camera by default (face-OTP context).
/// Requests the camera intrinsic matrix on the connection so the detector can
/// observe a signal that a file-backed source cannot forge in-process.
final class CameraCaptureService: NSObject, FrameSource {

    let kind: FrameSourceKind = .liveCamera
    weak var delegate: FrameSourceDelegate?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.capture.queue")

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { [weak self] in self?.configureAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.queue.async { self.configureAndRun() } }
                else { self.delegate?.frameSource(self, didFailWith: LabError.cameraAccessDenied) }
            }
        default:
            delegate?.frameSource(self, didFailWith: LabError.cameraAccessDenied)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureAndRun() {
        session.beginConfiguration()
        session.sessionPreset = .high

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)

        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            delegate?.frameSource(self, didFailWith: LabError.cameraUnavailable)
            return
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            delegate?.frameSource(self, didFailWith: LabError.outputUnavailable)
            return
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        session.commitConfiguration()
        session.startRunning()
    }
}

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        delegate?.frameSource(self, didOutput: FramePacket(
            sampleBuffer: sampleBuffer,
            kind: .liveCamera,
            receivedHostTime: CACurrentMediaTime()))
    }
}
