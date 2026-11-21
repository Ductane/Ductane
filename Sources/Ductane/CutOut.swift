import CoreGraphics
import Foundation
import ImageIO

/// **Whether a cut-out surface cuts anything out** — a material marked as clipped by its alpha whose texture has no pixel
/// under the cutoff is a solid surface, and is loaded as one.
///
/// Exporters mark whole models as cut out: a glTF tree whose bark and leaves are both `alphaMode: MASK`, the bark's
/// texture opaque in every pixel. Taken at its word, the trunk is a cut-out card — nothing a walker can stand against,
/// a prop counted with grass as ground cover, every bark pixel drawn through the slower clipping path, and shaded as a
/// leaf. Its pixels draw the same either way, since none falls under the cutoff.
///
/// **Read from the image file, at most 512 pixels across, once a file** (keyed by its path, size and date). A texture
/// inside a package, or a bundle resource, is left as the file says.
public nonisolated enum CutOut {

    /// Whether `file`'s alpha falls under `cutoff` anywhere — `true` when it cannot be read, so a surface that may cut
    /// stays cut out.
    public static func textureCuts(_ file: URL, below cutoff: Float) -> Bool {
        guard file.isFileURL, file.fragment(percentEncoded: false) == nil else { return true }
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = Key(path: file.standardizedFileURL.path, size: values?.fileSize ?? -1,
                      date: values?.contentModificationDate ?? .distantPast, cutoff: cutoff)
        if let known = lock.withLock({ known[key] }) { return known }
        let cuts = measure(file, below: cutoff)
        lock.withLock { known[key] = cuts }
        return cuts
    }

    /// The image's alpha against `cutoff`, read small. An image without an alpha channel cuts nothing.
    static func measure(_ file: URL, below cutoff: Float) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
                  kCGImageSourceShouldCacheImmediately: false,
              ] as CFDictionary) else { return true }
        return cuts(image, below: cutoff)
    }

    /// Whether any pixel of `image` has alpha under `cutoff`.
    static func cuts(_ image: CGImage, below cutoff: Float) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return true }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }
        let limit = UInt8(clamping: Int((min(max(cutoff, 0), 1) * 255).rounded(.up)))
        var index = 3
        while index < pixels.count {
            if pixels[index] < limit { return true }
            index += 4
        }
        return false
    }

    private struct Key: Hashable {
        let path: String
        let size: Int
        let date: Date
        let cutoff: Float
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [Key: Bool] = [:]
}

public nonisolated extension Material {

    /// **The material as it draws** — without its ``alphaCutoff`` when nothing is cut out (``CutOut``): its base colour's
    /// alpha times its texture's never falls under the cutoff.
    var cuttingOnlyWhereItCuts: Material {
        guard let cutoff = alphaCutoff, cutoff > 0 else { return self }
        guard baseColor.w >= cutoff else { return self }
        guard let source = textures[.baseColor] else { var solid = self; solid.alphaCutoff = nil; return solid }
        guard case .url(let file) = source else { return self }
        // The texture's alpha is multiplied by the base colour's: a pixel is cut where texel × factor < cutoff.
        if CutOut.textureCuts(file, below: cutoff / max(baseColor.w, 1e-6)) { return self }
        var solid = self
        solid.alphaCutoff = nil
        return solid
    }
}
