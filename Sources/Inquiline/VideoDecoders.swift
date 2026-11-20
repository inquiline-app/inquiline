import CoreMedia
import Foundation
import Security
import VideoToolbox

/// Android's video decoders, as a phone maker's are its own chip's: Inquiline's decoders in
/// Android (Vendor/c2) hand each video they are given to the engine, which decodes it with the
/// Mac's media engine (VideoToolbox) and copies each picture on the GPU straight into the buffer
/// Android shows it from (gfxstream's inquiline_video_decoder.mm). So videos play at the sizes a
/// phone plays them, 4K too, without Android's processors decoding them and without the Mac's
/// copying them.
///
/// Inquiline picks the loopback port and the token the engine listens with, and leaves them,
/// with the kinds of video this Mac decodes, where only Android's decoders read them; Android
/// reaches the port at 10.0.2.2, the Mac as the VM's network sees it.
final class VideoDecoders {
    static let shared = VideoDecoders()

    private let token: [UInt8] = {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes
    }()

    /// A port free on the Mac's loopback now, for the engine to listen on.
    let port: UInt16 = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return found ? UInt16(bigEndian: address.sin_port) : 0
    }()

    private var hexToken: String { token.map { String(format: "%02x", $0) }.joined() }

    /// What the engine listens with.
    var environment: [String: String] {
        port == 0 ? [:] : ["INQUILINE_DECODER_PORT": "\(port)", "INQUILINE_DECODER_TOKEN": hexToken]
    }

    /// What Android's decoders read: the port, the token in hex, and the kinds of video this Mac
    /// decodes in its hardware, which Android lists as its own.
    var key: String { "\(port) \(hexToken) " + Self.supported.map(\.name).joined(separator: ",") }

    /// H.264 and HEVC on every Mac Inquiline runs on; VP9 on Apple silicon; AV1 from M3 on.
    static let supported: [Codec] = Codec.allCases.filter { codec in
        if codec == .vp9 || codec == .av1 { VTRegisterSupplementalVideoDecoderIfAvailable(codec.type) }
        return VTIsHardwareDecodeSupported(codec.type)
    }
}

enum Codec: UInt8, CaseIterable {
    case avc = 1, vp9 = 2, av1 = 3, hevc = 4

    var name: String { "\(self)" }

    var type: CMVideoCodecType {
        switch self {
        case .avc: kCMVideoCodecType_H264
        case .vp9: kCMVideoCodecType_VP9
        case .av1: kCMVideoCodecType_AV1
        case .hevc: kCMVideoCodecType_HEVC
        }
    }
}
