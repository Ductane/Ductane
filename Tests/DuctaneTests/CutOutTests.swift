import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Ductane

/// A PNG with an alpha channel, every pixel `alpha` except a `hole` of `holeAlpha` in one corner.
private func png(alpha: UInt8, hole: Int = 0, holeAlpha: UInt8 = 0, named name: String) throws -> URL {
    let size = 64
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            let a = (x < hole && y < hole) ? holeAlpha : alpha
            let i = (y * size + x) * 4
            pixels[i] = a / 2; pixels[i + 1] = a / 3; pixels[i + 2] = a / 4; pixels[i + 3] = a
        }
    }
    let data = CFDataCreate(nil, pixels, pixels.count)!
    let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let folder = FileManager.default.temporaryDirectory.appending(path: "CutOutTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: "\(name).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

@Test func anOpaqueTextureCutsNothingAndALeafSheetDoes() throws {
    let bark = try png(alpha: 255, named: "bark")
    let leaves = try png(alpha: 255, hole: 40, named: "leaves")
    #expect(!CutOut.textureCuts(bark, below: 0.5))
    #expect(CutOut.textureCuts(leaves, below: 0.5))
    // Alpha just over the cutoff cuts nothing; just under, it cuts.
    #expect(!CutOut.textureCuts(try png(alpha: 255, hole: 16, holeAlpha: 140, named: "over"), below: 0.5))
    #expect(CutOut.textureCuts(try png(alpha: 255, hole: 16, holeAlpha: 110, named: "under"), below: 0.5))
    // A file that cannot be read is taken to cut, so it stays as the material says.
    #expect(CutOut.textureCuts(URL(filePath: "/nonexistent/none.png"), below: 0.5))
}

@Test func aMaterialMarkedCutOutLoadsSolidWhenItsTextureCutsNothing() throws {
    let bark = Material(name: "Bark", textures: [.baseColor: .url(try png(alpha: 255, named: "bark"))], alphaCutoff: 0.2)
    #expect(bark.cuttingOnlyWhereItCuts.alphaCutoff == nil)
    let leaves = Material(name: "Leaves", textures: [.baseColor: .url(try png(alpha: 255, hole: 40, named: "leaves"))],
                          alphaCutoff: 0.2)
    #expect(leaves.cuttingOnlyWhereItCuts.alphaCutoff == 0.2)
    // A base colour faded under the cutoff cuts everything, texture or not.
    var faded = bark
    faded.baseColor.w = 0.1
    #expect(faded.cuttingOnlyWhereItCuts.alphaCutoff == 0.2)
    // No texture and a solid colour: nothing to cut.
    #expect(Material(alphaCutoff: 0.5).cuttingOnlyWhereItCuts.alphaCutoff == nil)
    // A resource in a bundle is left as it is.
    #expect(Material(textures: [.baseColor: .named("x.png")], alphaCutoff: 0.5).cuttingOnlyWhereItCuts.alphaCutoff == 0.5)
}
