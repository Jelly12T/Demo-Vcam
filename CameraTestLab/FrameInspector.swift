import CoreMedia
import CoreVideo

struct FrameInfo {
    let width: Int
    let height: Int
    let pixelFormat: String        // FourCC, e.g. "420v", "420f", "BGRA"
    let planeCount: Int
    let bytesPerRowPlane0: Int
    let presentationTime: Double   // seconds
    let hasCameraIntrinsics: Bool
    let attachmentKeys: [String]

    var resolution: String { "\(width)x\(height)" }
}

enum FrameInspector {

    static func inspect(_ sampleBuffer: CMSampleBuffer) -> FrameInfo? {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let format = CVPixelBufferGetPixelFormatType(pb)

        let hasIntrinsics = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil) != nil

        var keys: [String] = []
        if let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = array.first {
            keys = first.keys.map { $0 as String }
        }

        return FrameInfo(
            width: CVPixelBufferGetWidth(pb),
            height: CVPixelBufferGetHeight(pb),
            pixelFormat: fourCC(format),
            planeCount: CVPixelBufferGetPlaneCount(pb),
            bytesPerRowPlane0: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
            presentationTime: CMTimeGetSeconds(pts),
            hasCameraIntrinsics: hasIntrinsics,
            attachmentKeys: keys)
    }

    static func fourCC(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        let s = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? String(format: "0x%08X", code) : s
    }
}
