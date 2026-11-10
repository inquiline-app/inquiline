import Compression
import Foundation

/// Reads an APK's manifest, a binary XML file inside a ZIP archive.
struct ApkManifest {
    let package: String
    let orientation: AppOrientation
    /// Whether the app says it's a game: android:appCategory="game", or the older android:isGame.
    let isGame: Bool

    init?(apk: URL) {
        guard let archive = try? Data(contentsOf: apk, options: .alwaysMapped),
              let manifest = Self.manifestEntry(in: archive),
              let parsed = Self.parse(manifest)
        else { return nil }
        self = parsed
    }

    /// The manifest file on its own, as taken out of an installed app.
    init?(manifest: Data) {
        guard let parsed = Self.parse(manifest) else { return nil }
        self = parsed
    }

    private init(package: String, orientation: AppOrientation, isGame: Bool) {
        self.package = package
        self.orientation = orientation
        self.isGame = isGame
    }

    // MARK: - ZIP

    private static func manifestEntry(in zip: Data) -> Data? {
        let endSignature: UInt32 = 0x0605_4B50
        let entrySignature: UInt32 = 0x0201_4B50
        guard zip.count >= 22 else { return nil }
        // The end record sits at the end, followed by a comment of up to 64 KB.
        var end = zip.count - 22
        let lowest = max(0, end - 0xFFFF)
        while end >= lowest, zip.uint32(at: end) != endSignature { end -= 1 }
        guard end >= lowest else { return nil }

        var entry = Int(zip.uint32(at: end + 16))
        for _ in 0..<Int(zip.uint16(at: end + 10)) {
            guard entry + 46 <= zip.count, zip.uint32(at: entry) == entrySignature else { return nil }
            let nameLength = Int(zip.uint16(at: entry + 28))
            let name = zip.subdata(in: entry + 46..<entry + 46 + nameLength)
            if name == Data("AndroidManifest.xml".utf8) {
                return unpack(from: zip, method: zip.uint16(at: entry + 10),
                              compressedSize: Int(zip.uint32(at: entry + 20)),
                              size: Int(zip.uint32(at: entry + 24)),
                              localHeader: Int(zip.uint32(at: entry + 42)))
            }
            entry += 46 + nameLength + Int(zip.uint16(at: entry + 30)) + Int(zip.uint16(at: entry + 32))
        }
        return nil
    }

    private static func unpack(from zip: Data, method: UInt16, compressedSize: Int, size: Int, localHeader: Int) -> Data? {
        guard localHeader + 30 <= zip.count else { return nil }
        let start = localHeader + 30 + Int(zip.uint16(at: localHeader + 26)) + Int(zip.uint16(at: localHeader + 28))
        guard start + compressedSize <= zip.count else { return nil }
        let stored = zip.subdata(in: start..<start + compressedSize)
        if method == 0 { return stored }
        guard method == 8, size > 0 else { return nil }

        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            stored.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, compressedSize,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return written == size ? output : nil
    }

    // MARK: - Binary XML

    private static func parse(_ xml: Data) -> ApkManifest? {
        let stringPoolChunk: UInt16 = 0x0001
        let resourceMapChunk: UInt16 = 0x0180
        let startElementChunk: UInt16 = 0x0102
        let nameAttribute: UInt32 = 0x0101_0003
        let orientationAttribute: UInt32 = 0x0101_001E
        let targetActivityAttribute: UInt32 = 0x0101_0202
        let isGameAttribute: UInt32 = 0x0101_03F4
        let appCategoryAttribute: UInt32 = 0x0101_0545
        let gameCategory: UInt32 = 0

        var strings: [String] = []
        var resources: [UInt32] = []
        var package: String?
        var orientations: [String: Int] = [:] // by activity name
        var aliasTargets: [String: String] = [:]
        var activity: String?
        var launcher: String?
        var isMain = false, isLauncher = false
        var isGame = false

        var offset = 8 // past the file header
        while offset + 8 <= xml.count {
            let type = xml.uint16(at: offset)
            let size = Int(xml.uint32(at: offset + 4))
            guard size >= 8, offset + size <= xml.count else { break }
            if type == stringPoolChunk, strings.isEmpty {
                strings = stringPool(in: xml, at: offset)
            } else if type == resourceMapChunk {
                resources = stride(from: offset + 8, to: offset + size, by: 4).map { xml.uint32(at: $0) }
            } else if type == startElementChunk {
                let element = Int(xml.uint32(at: offset + 16 + 4))
                let tag = element < strings.count ? strings[element] : ""
                let attributes = offset + 16 + Int(xml.uint16(at: offset + 16 + 8))
                let count = Int(xml.uint16(at: offset + 16 + 12))
                var name: String?, target: String?, orientation: Int?
                for index in 0..<count where attributes + index * 20 + 20 <= xml.count {
                    let attribute = attributes + index * 20
                    let nameIndex = Int(xml.uint32(at: attribute + 4))
                    let raw = Int(xml.uint32(at: attribute + 8))
                    let text = raw < strings.count ? strings[raw] : nil
                    let resource = nameIndex < resources.count ? resources[nameIndex] : 0
                    if resource == nameAttribute { name = text }
                    if resource == targetActivityAttribute { target = text }
                    if resource == orientationAttribute { orientation = Int(Int32(bitPattern: xml.uint32(at: attribute + 16))) }
                    if tag == "application", resource == isGameAttribute, xml.uint32(at: attribute + 16) != 0 { isGame = true }
                    if tag == "application", resource == appCategoryAttribute, xml.uint32(at: attribute + 16) == gameCategory { isGame = true }
                    if tag == "manifest", nameIndex < strings.count, strings[nameIndex] == "package" { package = text }
                }
                switch tag {
                case "activity", "activity-alias":
                    activity = name
                    if let name, let orientation { orientations[name] = orientation }
                    if let name, let target { aliasTargets[name] = target }
                case "intent-filter":
                    isMain = false
                    isLauncher = false
                case "action":
                    isMain = isMain || name == "android.intent.action.MAIN"
                case "category":
                    isLauncher = isLauncher || name == "android.intent.category.LAUNCHER"
                default:
                    break
                }
                if isMain, isLauncher, launcher == nil { launcher = activity }
            }
            offset += size
        }
        guard let package else { return nil }
        let start = launcher.flatMap { aliasTargets[$0] ?? $0 }
        let declared = start.flatMap { orientations[$0] } ?? launcher.flatMap { orientations[$0] }
        return ApkManifest(package: package, orientation: AppOrientation(screenOrientation: declared), isGame: isGame)
    }

    private static func stringPool(in xml: Data, at chunk: Int) -> [String] {
        let utf8Flag: UInt32 = 1 << 8
        let count = Int(xml.uint32(at: chunk + 8))
        let isUTF8 = xml.uint32(at: chunk + 16) & utf8Flag != 0
        let stringsStart = chunk + Int(xml.uint32(at: chunk + 20))
        return (0..<count).map { index in
            guard chunk + 28 + index * 4 + 4 <= xml.count else { return "" }
            let start = stringsStart + Int(xml.uint32(at: chunk + 28 + index * 4))
            return isUTF8 ? utf8String(in: xml, at: start) : utf16String(in: xml, at: start)
        }
    }

    /// Two lengths come first, in characters and in bytes, each one or two bytes long.
    private static func utf8String(in xml: Data, at start: Int) -> String {
        guard start + 2 <= xml.count else { return "" }
        var offset = start + (xml[xml.startIndex + start] & 0x80 != 0 ? 2 : 1)
        guard offset + 2 <= xml.count else { return "" }
        var length = Int(xml[xml.startIndex + offset])
        if length & 0x80 != 0 {
            length = (length & 0x7F) << 8 | Int(xml[xml.startIndex + offset + 1])
            offset += 2
        } else {
            offset += 1
        }
        guard offset + length <= xml.count else { return "" }
        return String(decoding: xml.subdata(in: offset..<offset + length), as: UTF8.self)
    }

    private static func utf16String(in xml: Data, at start: Int) -> String {
        guard start + 2 <= xml.count else { return "" }
        var offset = start + 2
        var length = Int(xml.uint16(at: start))
        if length & 0x8000 != 0 {
            guard start + 4 <= xml.count else { return "" }
            length = (length & 0x7FFF) << 16 | Int(xml.uint16(at: start + 2))
            offset += 2
        }
        guard offset + length * 2 <= xml.count else { return "" }
        return String(decoding: (0..<length).map { xml.uint16(at: offset + $0 * 2) }, as: UTF16.self)
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }
}
