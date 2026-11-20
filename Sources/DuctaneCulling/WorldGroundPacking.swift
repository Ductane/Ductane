//
//  WorldGroundPacking.swift
//  Ductane
//

/// **A ground texture set's maps packed into the two slices a renderer reads** (``WorldGroundTextures``), a texel at a
/// time: colour and height; the normal's x and y turned to DirectX's way up, roughness, occlusion.
///
/// Here, in the optimised module, because four 2048² sets done texel by texel in a Debug build took seconds — long enough
/// for an editor to show the ground in its colours after a texture was chosen.
public enum WorldGroundPacking {
    /// One map read as bytes, `channels` a texel (1 for grey, 4 for RGBA), rows top first.
    public struct Map {
        public let bytes: UnsafePointer<UInt8>
        public let channels: Int
        public init(bytes: UnsafePointer<UInt8>, channels: Int) {
            self.bytes = bytes
            self.channels = channels
        }
        @inline(__always) func at(_ texel: Int, _ channel: Int) -> UInt8 { bytes[texel * channels + min(channel, channels - 1)] }
    }

    /// Writes `texels` texels of both slices, RGBA each.
    public static func pack(texels: Int, colour: Map, height: Map?, normal: Map?, normalIsDirectX: Bool,
                            roughness: Map?, occlusion: Map?, packed: Map?, defaultRoughness: UInt8,
                            albedo: UnsafeMutablePointer<UInt8>, surface: UnsafeMutablePointer<UInt8>) {
        for i in 0..<texels {
            let o = i * 4
            albedo[o] = colour.at(i, 0)
            albedo[o + 1] = colour.at(i, 1)
            albedo[o + 2] = colour.at(i, 2)
            albedo[o + 3] = height?.at(i, 0) ?? 128
            if let normal {
                surface[o] = normal.at(i, 0)
                // Every normal map is turned to DirectX's way up — green toward the bottom of the image, which is +z on
                // the ground — so the shader reads them all alike.
                surface[o + 1] = normalIsDirectX ? normal.at(i, 1) : 255 - normal.at(i, 1)
            } else {
                surface[o] = 128
                surface[o + 1] = 128
            }
            surface[o + 2] = roughness?.at(i, 0) ?? packed?.at(i, 1) ?? defaultRoughness
            surface[o + 3] = occlusion?.at(i, 0) ?? packed?.at(i, 0) ?? 255
        }
    }
}
