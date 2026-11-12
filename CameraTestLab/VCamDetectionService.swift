import Foundation

struct DetectionResult {
    enum Verdict: String { case liveSensor = "Live sensor", injected = "Injected / VCam", uncertain = "Uncertain" }
    let verdict: Verdict
    let injectionScore: Double   // 0.0 = looks like real sensor, 1.0 = looks injected
    let reasons: [String]
}

/// Illustrative, client-side heuristics for telling a hardware capture feed apart
/// from an injected/replayed one. These are necessary-not-sufficient signals and
/// are individually bypassable — treat them as one layer behind on-device liveness
/// and server-side verification. Replace `evaluate` with your production detector;
/// the lab only needs this interface.
final class VCamDetectionService {

    private var lastPTS: Double?

    func reset() { lastPTS = nil }

    func evaluate(_ info: FrameInfo) -> DetectionResult {
        var score = 0.0
        var reasons: [String] = []

        // 1) Camera intrinsic matrix: a real capture connection can attach it;
        //    a frame synthesized from a file inside this process cannot.
        if info.hasCameraIntrinsics {
            reasons.append("Camera intrinsics present (sensor signal)")
        } else {
            score += 0.4
            reasons.append("No camera intrinsic matrix attachment")
        }

        // 2) Pixel format typical of the iOS capture pipeline (biplanar 420).
        if info.pixelFormat == "420v" || info.pixelFormat == "420f" {
            reasons.append("Pixel format \(info.pixelFormat) consistent with capture device")
        } else {
            score += 0.3
            reasons.append("Pixel format \(info.pixelFormat) atypical for a capture device")
        }

        // 3) Presentation timeline resets — a looping replay seeks back to zero.
        if let last = lastPTS, info.presentationTime + 0.001 < last {
            score += 0.3
            reasons.append("Presentation timestamp went backwards (replay loop)")
        }
        lastPTS = info.presentationTime

        score = min(score, 1.0)
        let verdict: DetectionResult.Verdict =
            score >= 0.6 ? .injected : (score <= 0.2 ? .liveSensor : .uncertain)
        return DetectionResult(verdict: verdict, injectionScore: score, reasons: reasons)
    }
}
