//
//  GLTFReader.swift
//  Ductane
//

import Draco
import Foundation
import simd

/// Why a glTF file could not be read.
public nonisolated enum GLTFError: Error, Equatable, CustomStringConvertible, Sendable {
    /// Not glTF, or damaged: the JSON does not parse, a chunk or a buffer is cut short, an accessor points
    /// outside its data, or compressed data does not decode.
    case unreadable(file: String)
    /// glTF, but not 2.0.
    case unsupportedVersion(file: String, version: String)
    /// The file lists an extension in `extensionsRequired` that this reader does not understand. Read anyway,
    /// its geometry or its look would come out wrong, so it is refused instead.
    case unsupportedExtension(file: String, name: String)
    /// A buffer the file keeps in another file — a `.bin` beside a `.gltf` — that could not be read: missing,
    /// or outside what the sandbox was given.
    case missingResource(file: String, resource: String)

    public var description: String {
        switch self {
        case .unreadable(let file):
            "\(file) could not be read as glTF."
        case .unsupportedVersion(let file, let version):
            "\(file) is glTF \(version). Only glTF 2.0 is read."
        case .unsupportedExtension(let file, let name):
            "\(file) requires the glTF extension \(name), which Ductane does not read. Exporting it again "
                + "without that extension usually works."
        case .missingResource(let file, let resource):
            "\(file) keeps its data in \(resource), which could not be read. A sandboxed app can read a file beside "
                + "a .gltf only when it has the same name, such as \((file as NSString).deletingPathExtension).bin, "
                + "and the app declares that type as a related item; otherwise check the file is there."
        }
    }
}

public nonisolated extension ImportedModel {

    /// The file extensions ``read(gltf:reportingTo:)`` reads.
    static let gltfFileExtensions: Set<String> = ["gltf", "glb"]

    /// Reads a glTF 2.0 file — `.gltf`, with its buffers embedded or in files beside it, or `.glb`.
    ///
    /// Every mesh in the default scene comes out placed by its node's transform, with its materials and their
    /// images. A skinned mesh comes out standing still, where its joints stand at rest: its skeleton, skin and clips
    /// are read by ``RigLoader`` and ``SkinnedModel``, which take glTF as they take USD. Compressed files are read —
    /// meshopt, Draco, quantized attributes and KTX2 textures.
    ///
    /// - Parameter report: told about anything left out on the way — an image that could not be read, lines or
    ///   points that are not triangles — which does not stop the rest being read.
    /// - Throws: ``GLTFError``.
    static func read(gltf url: URL, reportingTo report: ((String) -> Void)? = nil) throws -> ImportedModel {
        try GLTFReader.read(url: url, reportingTo: report)
    }
}

/// Reads glTF 2.0 into an ``ImportedModel``. Written in Swift, because nothing Apple ships reads glTF.
///
/// **Extracted from a character-creator app's reader.** What a prop needs from a file is narrower than what glTF can
/// say, and the rest is read past rather than refused: cameras, lights and morph targets are ignored, and a prop is
/// read without its skin and clips — a character's are read by ``GLTFCharacter``, further down. Only a file that
/// *requires* an extension this does not understand is turned away, because its geometry or its look would otherwise
/// come out as garbage.
///
/// - **Every mesh is placed by its node's world transform**, composed from the scene's roots — all the nodes of
///   the default scene, or every node nothing parents when the file has no scenes, which glTF allows.
/// - **A skinned mesh comes out in its bind pose.** glTF places a skinned mesh by its joints and ignores its
///   node, so its placement is what the joints say at rest: each joint's world transform times its inverse
///   bind matrix. When every joint agrees — the usual case — that matrix is the mesh's transform. An exporter
///   may fold a transform of its own into every inverse bind (gltfpack does, to turn quantized integers back
///   into metres), and reading the node instead would leave such a mesh thousands of units wide. When the
///   joints disagree, the rig was posed away from its bind, and the node's transform is used.
nonisolated enum GLTFReader {

    /// Extensions whose presence in `extensionsRequired` changes nothing this reader gets wrong.
    /// KHR_mesh_quantization allows integer positions and normals, which the accessor reader already converts.
    /// KHR_materials_unlit's fallback is the lit material it sits on, which is what is read.
    private static let understoodExtensions: Set<String> = [
        "KHR_mesh_quantization", "KHR_materials_unlit", "EXT_meshopt_compression", "KHR_meshopt_compression",
        "KHR_draco_mesh_compression", "KHR_materials_emissive_strength", "KHR_texture_transform", "EXT_texture_webp",
        "KHR_texture_basisu",
    ]

    static func read(url: URL, reportingTo report: ((String) -> Void)?) throws -> ImportedModel {
        try reader(url: url, reportingTo: report).read()
    }

    /// A skinned character: its skeleton, clips and — when `withMeshes` — its skinned meshes. See ``GLTFCharacter``.
    static func character(url: URL, withMeshes: Bool, reportingTo report: ((String) -> Void)?) throws -> GLTFCharacter {
        try reader(url: url, reportingTo: report).character(withMeshes: withMeshes)
    }

    private static func reader(url: URL, reportingTo report: ((String) -> Void)?) throws -> Reader {
        let file = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw GLTFError.unreadable(file: file) }
        let (json, glbBinary) = try container(data, file: file)
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: json)
        } catch {
            throw GLTFError.unreadable(file: file)
        }
        guard document.asset.version.hasPrefix("2.") else {
            throw GLTFError.unsupportedVersion(file: file, version: document.asset.version)
        }
        if let required = document.extensionsRequired?.first(where: { !understoodExtensions.contains($0) }) {
            throw GLTFError.unsupportedExtension(file: file, name: required)
        }
        let buffers = try (document.buffers ?? []).enumerated().map { index, buffer in
            try load(buffer, index: index, glbBinary: glbBinary, beside: url)
        }
        return try Reader(document: document, buffers: buffers, url: url, report: report)
    }

    // MARK: Containers and buffers

    /// The JSON, and the binary chunk when the file is a `.glb`.
    private static func container(_ data: Data, file: String) throws -> (json: Data, binary: Data?) {
        guard data.count >= 12, data.word(at: 0) == 0x4654_6C67 else { return (data, nil) }   // "glTF"
        guard data.word(at: 4) == 2 else {
            throw GLTFError.unsupportedVersion(file: file, version: String(data.word(at: 4)))
        }
        var json: Data?, binary: Data?
        var offset = 12
        let end = min(Int(data.word(at: 8)), data.count)
        while offset + 8 <= end {
            let length = Int(data.word(at: offset)), type = data.word(at: offset + 4)
            let start = offset + 8
            guard start + length <= end else { throw GLTFError.unreadable(file: file) }
            let chunk = data.subdata(in: start..<start + length)
            if type == 0x4E4F_534A, json == nil { json = chunk }          // "JSON"
            if type == 0x004E_4942, binary == nil { binary = chunk }      // "BIN\0"
            offset = start + length
        }
        guard let json else { throw GLTFError.unreadable(file: file) }
        return (json, binary)
    }

    private static func load(_ buffer: Document.Buffer, index: Int, glbBinary: Data?, beside url: URL) throws -> Data {
        let file = url.lastPathComponent
        let data: Data
        if let uri = buffer.uri {
            if uri.hasPrefix("data:") {
                guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
                      let decoded = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                    throw GLTFError.unreadable(file: file)
                }
                data = decoded
            } else {
                // Relative to the file, percent-encoded as a URI.
                let path = uri.removingPercentEncoding ?? uri
                let resource = URL(filePath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                guard let read = (try? Data(contentsOf: resource)) ?? RelatedFile.read(resource, beside: url) else {
                    throw GLTFError.missingResource(file: file, resource: path)
                }
                data = read
            }
        } else if index == 0, let glbBinary {
            data = glbBinary
        } else {
            // A placeholder: the space a compressed view decodes into, with nothing stored. Only a view
            // that is decoded may point into it, and `bytes(view:)` refuses any other.
            return Data()
        }
        guard data.count >= buffer.byteLength else { throw GLTFError.unreadable(file: file) }
        return data
    }
}

// MARK: A file beside the one opened

/// Reads a file that sits beside one the person opened — a `.gltf`'s `.bin` — which the sandbox has not
/// granted, because only the file chosen was.
///
/// **macOS's answer is a related item**: the app declares the neighbour's type with
/// `NSIsRelatedItemType` in its Info.plist, and reads it through a file presenter whose primary item is
/// the file that *was* granted. The coordinated read is what extends the sandbox to it. Outside a
/// sandbox, or for a file already reachable, it is never needed — which is why it is only the fallback.
///
/// **macOS grants a related item only if it shares the primary file's name**: `hero.gltf` reaches
/// `hero.bin`, never `hero data.bin`. Blender and most exporters write the matching name. Measured in a
/// sandboxed app, since the sandbox cannot be reproduced under `swift test`.
private nonisolated final class RelatedFile: NSObject, NSFilePresenter, @unchecked Sendable {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    private init(_ url: URL, primary: URL) {
        presentedItemURL = url
        primaryPresentedItemURL = primary
    }

    static func read(_ url: URL, beside primary: URL) -> Data? {
        let presenter = RelatedFile(url, primary: primary)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        var data: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &error) {
            data = try? Data(contentsOf: $0)
        }
        return data
    }
}

// MARK: Reading the document

private nonisolated struct Reader {
    let document: Document
    let buffers: [Data]
    let file: String
    let report: ((String) -> Void)?

    /// Parent of every node, and the order a depth-first walk of the scene meets them.
    fileprivate let parents: [Int?]
    fileprivate let sceneOrder: [Int]

    /// Compressed buffer views, decoded once, by view index. Everything downstream reads these as if
    /// the file had never been compressed.
    private let decoded: [Int: Data]

    /// The file itself, for finding images beside it.
    let url: URL
    /// Decoded images, shared by every material that uses them. A class so a `Reader` value can fill
    /// it as materials ask.
    fileprivate let images = ImageCache()

    init(document: Document, buffers: [Data], url: URL, report: ((String) -> Void)?) throws {
        self.document = document
        self.buffers = buffers
        self.file = url.lastPathComponent
        self.url = url
        self.report = report
        var decoded: [Int: Data] = [:]
        for (index, view) in (document.bufferViews ?? []).enumerated() {
            guard let meshopt = view.extensions?.meshopt else { continue }
            guard let source = buffers[safe: meshopt.buffer],
                  let mode = MeshoptDecoder.Mode(rawValue: meshopt.mode),
                  let filter = MeshoptDecoder.Filter(rawValue: meshopt.filter ?? "NONE") else {
                throw GLTFError.unreadable(file: file)
            }
            let start = meshopt.byteOffset ?? 0
            guard start >= 0, start + meshopt.byteLength <= source.count,
                  let data = try? MeshoptDecoder.decode(source.subdata(in: start..<start + meshopt.byteLength),
                                                        count: meshopt.count, stride: meshopt.byteStride,
                                                        mode: mode, filter: filter),
                  data.count >= view.byteLength else {
                throw GLTFError.unreadable(file: file)
            }
            decoded[index] = data
        }
        self.decoded = decoded
        let nodes = document.nodes ?? []
        var parents = [Int?](repeating: nil, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            for child in node.children ?? [] where nodes.indices.contains(child) { parents[child] = index }
        }
        self.parents = parents
        // The default scene's roots, or — for a file with no scenes, which glTF allows — every node
        // nothing else parents.
        let roots: [Int]
        if let scenes = document.scenes, !scenes.isEmpty {
            roots = scenes[min(document.scene ?? 0, scenes.count - 1)].nodes ?? []
        } else {
            roots = nodes.indices.filter { parents[$0] == nil }
        }
        var order: [Int] = [], seen = Set<Int>()
        func walk(_ index: Int) {
            guard nodes.indices.contains(index), seen.insert(index).inserted else { return }
            order.append(index)
            for child in nodes[index].children ?? [] { walk(child) }
        }
        roots.forEach(walk)
        sceneOrder = order
    }

    fileprivate var nodes: [Document.Node] { document.nodes ?? [] }

    func read() throws -> ImportedModel {
        // Every material in the file, in its order, so a submesh's index is the file's own.
        let materials = (document.materials ?? []).map(material)
        var meshes: [ImportedMesh] = []
        for index in sceneOrder {
            guard let meshIndex = nodes[index].mesh, let mesh = document.meshes?[safe: meshIndex] else { continue }
            if let made = try makeMesh(mesh, node: index, materialCount: materials.count) { meshes.append(made) }
        }
        for path in images.missing { report?("\(file): the image \(path) could not be read") }
        return ImportedModel(meshes: meshes, materials: materials)
    }

    /// Two matrices equal to a tolerance scaled by their size, so a matrix holding quantization's tiny
    /// scale is compared as carefully as one holding metres.
    fileprivate static func same(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
        let scale = max(1e-6, (0..<4).flatMap { c in (0..<4).map { max(abs(a[c][$0]), abs(b[c][$0])) } }.max() ?? 1)
        return (0..<4).allSatisfy { c in (0..<4).allSatisfy { abs(a[c][$0] - b[c][$0]) <= scale * 1e-4 } }
    }

    /// Where a skinned mesh stands at bind: what every one of its joints, at rest, times its inverse bind
    /// matrix agrees on — see ``GLTFReader``. Nil when they disagree, or the skin has no joints in the file.
    private func bindPlacement(of skin: Document.Skin) throws -> simd_float4x4? {
        let matrices: [simd_float4x4] = try skin.inverseBindMatrices.map { try readMatrices($0) } ?? []
        let shapes = skin.joints.enumerated().compactMap { position, node -> simd_float4x4? in
            nodes.indices.contains(node) ? worldTransform(of: node) * (matrices[safe: position] ?? matrix_identity_float4x4) : nil
        }
        guard let shape = shapes.first, shapes.allSatisfy({ Self.same($0, shape) }), abs(shape.determinant) > 1e-12
        else { return nil }
        return shape
    }

    // MARK: Meshes

    /// One node's mesh: every triangle primitive, its vertices appended to the mesh's, one submesh each.
    private func makeMesh(_ mesh: Document.Mesh, node: Int, materialCount: Int) throws -> ImportedMesh? {
        try makeMesh(mesh, node: node, materialCount: materialCount, skin: nil)?.mesh
    }

    /// The same, and with `skin` — the skeleton's joint for each of the skin's — every vertex's four influences too,
    /// read alongside its position so the two stay one per vertex.
    private func makeMesh(_ mesh: Document.Mesh, node: Int, materialCount: Int, skin remap: [UInt16]?) throws
        -> (mesh: ImportedMesh, influences: [Influence])? {
        var influences: [Influence] = []
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = [], colors: [SIMD4<Float>] = []
        var submeshes: [ImportedSubmesh] = []
        // Normals for every vertex or none: a primitive without them, merged with one that has them, has its
        // own made from its faces; a mesh where no primitive has any leaves them to whoever draws it.
        var withoutNormals: [(range: Range<Int>, indices: [UInt32])] = []
        let name = mesh.name ?? nodes[node].name ?? "mesh \(node)"

        for primitive in mesh.primitives {
            let mode = primitive.mode ?? 4
            guard [4, 5, 6].contains(mode) else {
                // Points and lines: nothing a surface renderer draws.
                report?("\(file): \(name) has points or lines, which were left out")
                continue
            }
            guard primitive.attributes["POSITION"] != nil else { continue }
            // Where this primitive's data lives: its accessors, or — Draco-compressed — one buffer view
            // decoded as a whole, with the accessors describing only what comes out.
            let source = try PrimitiveSource(primitive, reader: self)
            let base = positions.count
            let primitivePositions = try source.floats("POSITION", components: 3).map { SIMD3($0[0], $0[1], $0[2]) }
            let count = primitivePositions.count
            var indices = try source.indices() ?? Array(0..<UInt32(count))
            indices = triangles(indices, mode: mode)
            guard indices.allSatisfy({ Int($0) < count }) else { throw GLTFError.unreadable(file: file) }

            if source.has("NORMAL") {
                let read = try source.floats("NORMAL", components: 3).map { simd_normalize(SIMD3($0[0], $0[1], $0[2])) }
                guard read.count == count else { throw GLTFError.unreadable(file: file) }
                normals += Array(repeating: .zero, count: base - normals.count) + read
            } else {
                withoutNormals.append((base..<base + count, indices))
            }
            // Texture coordinates and colours for every vertex or none: a primitive without them, merged with
            // one that has them, gets zeros — which sample a texture's corner rather than reading past — and
            // white, which leaves the material's colour alone.
            if source.has("TEXCOORD_0") {
                uvs += Array(repeating: .zero, count: base - uvs.count)
                let read = try source.floats("TEXCOORD_0", components: 2).map { SIMD2($0[0], $0[1]) }
                guard read.count == count else { throw GLTFError.unreadable(file: file) }
                uvs += read
            }
            if source.has("COLOR_0") {
                let width = source.components("COLOR_0") == 4 ? 4 : 3
                colors += Array(repeating: SIMD4(repeating: 1), count: base - colors.count)
                let read = try source.floats("COLOR_0", components: width).map {
                    SIMD4($0[0], $0[1], $0[2], width == 4 ? $0[3] : 1)
                }
                guard read.count == count else { throw GLTFError.unreadable(file: file) }
                colors += read
            }
            if let remap { influences += try self.influences(source, count: count, remap: remap) }
            positions += primitivePositions
            guard !indices.isEmpty else { continue }
            let material = primitive.material.flatMap { (0..<materialCount).contains($0) ? $0 : nil }
            submeshes.append(ImportedSubmesh(indices: indices.map { $0 + UInt32(base) }, material: material))
        }
        guard !submeshes.isEmpty else { return nil }
        if !uvs.isEmpty { uvs += Array(repeating: .zero, count: positions.count - uvs.count) }
        if !colors.isEmpty { colors += Array(repeating: SIMD4(repeating: 1), count: positions.count - colors.count) }
        if !normals.isEmpty {
            normals += Array(repeating: .zero, count: positions.count - normals.count)
            for (range, indices) in withoutNormals {
                let made = ImportedMesh.smoothNormals(Array(positions[range]), indices)
                normals.replaceSubrange(range, with: made)
            }
        }

        var transform = worldTransform(of: node)
        if let skin = nodes[node].skin.flatMap({ document.skins?[safe: $0] }), let placed = try bindPlacement(of: skin) {
            transform = placed
        }
        return (ImportedMesh(name: name, transform: transform, positions: positions, normals: normals, uvs: uvs,
                             colors: colors, submeshes: submeshes), influences)
    }

    // MARK: Materials

    /// A glTF material, factors and textures both, as glTF defines them.
    fileprivate func material(_ m: Document.Material) -> ImportedMaterial {
        let pbr = m.pbrMetallicRoughness
        let base = pbr?.baseColorFactor ?? [1, 1, 1, 1]
        let emissive = m.emissiveFactor ?? [0, 0, 0]
        let strength = m.extensions?.emissiveStrength?.emissiveStrength ?? 1
        return ImportedMaterial(
            name: m.name ?? "",
            baseColor: SIMD4(base[safe: 0] ?? 1, base[safe: 1] ?? 1, base[safe: 2] ?? 1, base[safe: 3] ?? 1),
            baseColorTexture: texture(pbr?.baseColorTexture),
            metallic: pbr?.metallicFactor ?? 1,
            roughness: pbr?.roughnessFactor ?? 1,
            metallicRoughnessTexture: texture(pbr?.metallicRoughnessTexture),
            normalTexture: texture(m.normalTexture),
            normalScale: m.normalTexture?.scale ?? 1,
            occlusionTexture: texture(m.occlusionTexture),
            occlusionStrength: m.occlusionTexture?.strength ?? 1,
            emissive: SIMD3(emissive[safe: 0] ?? 0, emissive[safe: 1] ?? 0, emissive[safe: 2] ?? 0) * strength,
            emissiveTexture: texture(m.emissiveTexture),
            alphaMode: ImportedMaterial.AlphaMode(rawValue: (m.alphaMode ?? "OPAQUE").lowercased()) ?? .opaque,
            alphaCutoff: m.alphaCutoff ?? 0.5,
            doubleSided: m.doubleSided ?? false)
    }

    /// A texture a material names, or nil when its image cannot be had — missing, unreadable, or in a
    /// format nothing here decodes. The material then draws with its factor alone, which is what a
    /// careful engine does too, and the image is reported.
    private func texture(_ info: Document.TextureInfo?) -> ImportedTextureReference? {
        guard let info, let texture = document.textures?[safe: info.index],
              let imageIndex = texture.extensions?.basisu?.source ?? texture.extensions?.webp?.source ?? texture.source,
              let image = self.image(imageIndex) else { return nil }
        let sampler = texture.sampler.flatMap { document.samplers?[safe: $0] }
        func wrap(_ mode: Int?) -> ImportedTextureReference.Wrap {
            switch mode { case 33071: .clamp; case 33648: .mirror; default: .repeating }
        }
        var transform = matrix_identity_float3x3
        if let t = info.extensions?.transform {
            // KHR_texture_transform: translation × rotation × scale, applied to (u, v, 1).
            let o = t.offset ?? [0, 0], s = t.scale ?? [1, 1], r = t.rotation ?? 0
            let translation = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(o[safe: 0] ?? 0, o[safe: 1] ?? 0, 1))
            let rotation = simd_float3x3(SIMD3(cos(r), -sin(r), 0), SIMD3(sin(r), cos(r), 0), SIMD3(0, 0, 1))
            let scale = simd_float3x3(diagonal: SIMD3(s[safe: 0] ?? 1, s[safe: 1] ?? 1, 1))
            transform = translation * rotation * scale
        }
        return ImportedTextureReference(texture: image, wrapS: wrap(sampler?.wrapS), wrapT: wrap(sampler?.wrapT),
                                        nearest: sampler?.magFilter == 9728, transform: transform)
    }

    private func image(_ index: Int) -> ImportedTexture? {
        if let known = images.textures[index] { return known }
        guard !images.failed.contains(index), let image = document.images?[safe: index] else { return nil }
        let name = image.name ?? image.uri.map { ($0.removingPercentEncoding ?? $0) } ?? "image \(index)"
        var data: Data?
        if let uri = image.uri {
            if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
                data = Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            } else {
                let path = uri.removingPercentEncoding ?? uri
                let resource = URL(filePath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                data = (try? Data(contentsOf: resource)) ?? RelatedFile.read(resource, beside: url)
                if data == nil { images.missing.append(path) }
            }
        } else if let view = image.bufferView, let length = document.bufferViews?[safe: view]?.byteLength,
                  let (bytes, start, _) = try? bytes(view: view, byteOffset: 0, elementSize: 1, count: length) {
            data = bytes.subdata(in: start..<start + length)
        }
        guard let data, let texture = ImportedTexture(name: name, encoded: data) else {
            if data != nil { report?("\(file): the image \(name) is in a format that could not be decoded") }
            images.failed.insert(index)
            return nil
        }
        images.textures[index] = texture
        return texture
    }

    /// Root first, ending at the node itself.
    fileprivate func ancestry(of node: Int) -> [Int] {
        var chain = [node], at = node
        while let parent = parents[at], !chain.contains(parent) { chain.append(parent); at = parent }
        return chain.reversed()
    }

    fileprivate func worldTransform(of node: Int) -> simd_float4x4 {
        ancestry(of: node).reduce(matrix_identity_float4x4) { $0 * TRS(nodes[$1]).matrix }
    }

    /// Strips and fans unrolled into a plain triangle list, with degenerate triangles dropped.
    private func triangles(_ indices: [UInt32], mode: Int) -> [UInt32] {
        guard mode != 4, indices.count >= 3 else { return Array(indices.prefix(indices.count / 3 * 3)) }
        var out: [UInt32] = []
        for i in 2..<indices.count {
            let tri = mode == 5
                ? (i % 2 == 0 ? [indices[i - 2], indices[i - 1], indices[i]] : [indices[i - 1], indices[i - 2], indices[i]])
                : [indices[0], indices[i - 1], indices[i]]
            if Set(tri).count == 3 { out += tri }
        }
        return out
    }

    // MARK: Accessors

    /// An accessor's elements as floats, `components` per element, normalised integers converted as
    /// the specification says. `rawIntegers` reads integer data as its plain value — indices.
    fileprivate func readFloats(_ index: Int, components: Int, rawIntegers: Bool = false) throws -> [[Float]] {
        guard let accessor = document.accessors?[safe: index],
              let width = Document.Accessor.components[accessor.type], width >= components || accessor.type == "SCALAR" else {
            throw GLTFError.unreadable(file: file)
        }
        var values = [[Float]](repeating: [Float](repeating: 0, count: width), count: accessor.count)
        if let view = accessor.bufferView {
            let (data, offset, stride) = try bytes(view: view, byteOffset: accessor.byteOffset ?? 0,
                                                    elementSize: accessor.componentSize * width, count: accessor.count)
            let normalized = accessor.normalized == true && !rawIntegers
            data.withUnsafeBytes { raw in
                for element in 0..<accessor.count {
                    for c in 0..<width {
                        values[element][c] = Self.component(raw, at: offset + element * stride + c * accessor.componentSize,
                                                            type: accessor.componentType, normalized: normalized)
                    }
                }
            }
        }
        if let sparse = accessor.sparse {
            let at = try readIndices(sparse.indices, count: sparse.count)
            let (data, offset, _) = try bytes(view: sparse.values.bufferView, byteOffset: sparse.values.byteOffset ?? 0,
                                               elementSize: accessor.componentSize * width, count: sparse.count)
            data.withUnsafeBytes { raw in
                for (n, element) in at.enumerated() where Int(element) < accessor.count {
                    for c in 0..<width {
                        values[Int(element)][c] = Self.component(raw, at: offset + (n * width + c) * accessor.componentSize,
                                                                 type: accessor.componentType,
                                                                 normalized: accessor.normalized == true && !rawIntegers)
                    }
                }
            }
        }
        return values
    }

    /// Index data, of any integer width.
    fileprivate func readIndices(_ index: Int) throws -> [UInt32] {
        guard let accessor = document.accessors?[safe: index] else { throw GLTFError.unreadable(file: file) }
        return try readFloats(index, components: 1, rawIntegers: true).map { UInt32($0[0]) }
            .prefix(accessor.count).map { $0 }
    }

    /// A sparse accessor's indices, which live in their own small block rather than an accessor.
    private func readIndices(_ sparse: Document.Accessor.Sparse.Indices, count: Int) throws -> [UInt32] {
        let size = sparse.componentType == 5121 ? 1 : sparse.componentType == 5123 ? 2 : 4
        let (data, offset, _) = try bytes(view: sparse.bufferView, byteOffset: sparse.byteOffset ?? 0,
                                           elementSize: size, count: count)
        return data.withUnsafeBytes { raw in
            (0..<count).map { UInt32(Self.component(raw, at: offset + $0 * size, type: sparse.componentType, normalized: false)) }
        }
    }

    fileprivate func readMatrices(_ index: Int) throws -> [simd_float4x4] {
        try readFloats(index, components: 16).map { m in
            simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                    SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
        }
    }

    /// A buffer view's bytes, where its first element starts, and the distance between elements —
    /// checked to lie inside the buffer, so a truncated file is refused rather than read past.
    fileprivate func bytes(view index: Int, byteOffset: Int, elementSize: Int, count: Int) throws -> (Data, Int, Int) {
        guard let view = document.bufferViews?[safe: index] else { throw GLTFError.unreadable(file: file) }
        if let data = decoded[index] {
            // Decoded views start at their own first byte.
            let stride = view.byteStride ?? elementSize
            let needed = count == 0 ? 0 : (count - 1) * stride + elementSize
            guard byteOffset >= 0, stride >= elementSize || count <= 1, byteOffset + needed <= data.count else {
                throw GLTFError.unreadable(file: file)
            }
            return (data, byteOffset, stride)
        }
        guard let buffer = buffers[safe: view.buffer] else { throw GLTFError.unreadable(file: file) }
        let stride = view.byteStride ?? elementSize
        let start = (view.byteOffset ?? 0) + byteOffset
        let needed = count == 0 ? 0 : (count - 1) * stride + elementSize
        guard start >= 0, stride >= elementSize || count <= 1,
              start + needed <= (view.byteOffset ?? 0) + view.byteLength,
              (view.byteOffset ?? 0) + view.byteLength <= buffer.count else {
            throw GLTFError.unreadable(file: file)
        }
        return (buffer, start, stride)
    }

    private static func component(_ raw: UnsafeRawBufferPointer, at offset: Int, type: Int, normalized: Bool) -> Float {
        switch type {
        case 5120: let v = Float(raw.loadUnaligned(fromByteOffset: offset, as: Int8.self)); return normalized ? max(v / 127, -1) : v
        case 5121: let v = Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self)); return normalized ? v / 255 : v
        case 5122: let v = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
            return normalized ? max(v / 32767, -1) : v
        case 5123: let v = Float(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            return normalized ? v / 65535 : v
        case 5125: return Float(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        default: return Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }
    }
}

// MARK: Characters

/// A skinned character read out of glTF — its skeleton, its clips and its skinned meshes — for ``RigLoader`` and
/// ``SkinnedGeometry`` to make theirs from, so the two read one file the same way.
///
/// **The same shape as a character read from USD.** glTF says a rig differently, and each difference is settled here:
///
/// - **Joints are nodes, in any order, under any nodes.** They are taken in the skin's own order when it is parent
///   first — what every exporter met writes, and the order the same character's USD export has — and in the scene's
///   order otherwise. A joint is named by its path of joint names, `Hips/Spine/Neck`, as USD names it.
/// - **What stands above the root joint is the rig's place in the file**, ``Rig/nodeTransform`` — the armature an
///   exporter puts there, with its unit scale or axis turn: an exported character in centimetres under a parent scaled
///   by 0.01 keeps its centimetres, as its USD export does. A node *between* two joints is not a joint and has nowhere
///   else to go, so its transform is folded into the joint beneath it, at rest and in every key of every clip.
/// - **glTF has no rest pose apart from where the joints stand**, so a joint's node transform is its rest, and the
///   skin's inverse bind matrices say where the mesh was bound.
/// - **A skin's vertices are put into the skeleton's space at rest.** glTF only promises that a joint's world transform
///   times its inverse bind matrix places a vertex, and an exporter may fold a transform of its own into every inverse
///   bind — gltfpack does, to turn quantized integers back into metres. When every joint of a skin, standing where the
///   file has it, times its inverse bind gives the same matrix, that matrix is where the skin's vertices stand: it is
///   moved into the vertices and out of the inverse binds, so the skeleton's inverse binds are each joint's rest
///   inverted, as a USD file's are. When they disagree the rig was saved posed away from its bind, and the file is
///   taken as written. Either way a vertex skins to exactly where glTF says it goes.
/// - **A mesh hung under a joint without a skin is a rigid attachment**, as a sword in a hand is usually exported: it
///   is bound wholly to that joint, as USD's constant joint influences bind one. A mesh neither skinned nor under a
///   joint is not part of the character, and is left out, as the USD reader leaves out a mesh with no joints.
/// - **A clip is every key any of its channels has**, its joints sampled at each — the engine's clips keep one set of
///   times per channel, glTF one per joint. Linear keys are kept exactly: a straight line or a slerp sampled at its own
///   breakpoints and the points between is the same curve. A step is kept as a step, by a second key at the instant it
///   changes. A cubic spline bends between its keys, so it is sampled thirty times a second as well. **Its times start
///   at zero**, as the same clip's do from USD, wherever the file's first key is.
/// - **Up to eight influences are read** (`JOINTS_1` and `WEIGHTS_1` beside the first four), and a vertex keeps its four
///   strongest, its weights made to sum to one again.
nonisolated struct GLTFCharacter: Sendable {
    /// Nil for a file with no skin — an animation-only file. Its clips then name, as joints, the nodes they move and
    /// the nodes between them, from the topmost node moved down.
    let skeleton: Skeleton?
    /// Where the skeleton stands in the file: the world transform of the root joint's parent.
    let nodeTransform: simd_float4x4
    let clips: [AnimationClip]
    /// Clips left out, and why.
    let droppedClips: [(clip: String, reason: String)]
    /// The skinned meshes and rigid attachments, in skeleton space at rest, with the file's materials. Empty unless
    /// meshes were asked for.
    let model: ImportedModel
    /// Per mesh of ``model``, per vertex: four joints of ``skeleton`` and their weights, summing to one.
    let influences: [[Influence]]
}

/// A vertex's four joints and their weights.
nonisolated struct Influence: Sendable, Equatable {
    var joints: SIMD4<UInt16>
    var weights: SIMD4<Float>
}

private nonisolated extension Reader {

    /// The joints of a rig, and how glTF's nodes reach them.
    struct Joints {
        let paths: [String]
        /// Node index → joint index.
        let jointOfNode: [Int: Int]
        /// Joint index → node index.
        let nodeOfJoint: [Int]
        /// The root joint's parent's world transform: where the rig stands in the file.
        let nodeTransform: simd_float4x4
        /// Per joint: what lies between it and its parent joint — the nodes that are not joints, or for a root, its
        /// parent's world transform relative to ``nodeTransform``. Identity almost always.
        let between: [simd_float4x4]
        /// Per joint: its node's own transform.
        let rest: [JointTransform]

        /// Per joint: relative to its parent joint, with what lies between folded in.
        var restLocal: [simd_float4x4] { zip(between, rest).map { $0 * $1.matrix } }
    }

    func character(withMeshes: Bool) throws -> GLTFCharacter {
        let skins = document.skins ?? []
        var skeleton: Skeleton?
        var joints: Joints?
        var vertexTransforms: [Int: simd_float4x4] = [:]
        if let skinned = skinJoints(skins) {
            let rig = makeJoints(skinned)
            let local = rig.restLocal
            var modelRest: [simd_float4x4] = []
            for (joint, node) in rig.nodeOfJoint.enumerated() {
                let parent = nearestJoint(above: node, in: rig.jointOfNode)
                modelRest.append((parent.map { modelRest[$0] } ?? matrix_identity_float4x4) * local[joint])
            }
            let undoPlacement = rig.nodeTransform.inverse
            // Inverse binds from whichever skin names a joint first, with the skin's own placement taken out — see
            // ``GLTFCharacter``. A joint no skin gives a matrix (glTF allows leaving them out) is bound where it stands.
            var inverseBinds = [simd_float4x4?](repeating: nil, count: rig.paths.count)
            for (index, skin) in skins.enumerated() {
                let matrices = try skin.inverseBindMatrices.map { try readMatrices($0) } ?? []
                let shapes = skin.joints.enumerated().compactMap { position, node -> simd_float4x4? in
                    nodes.indices.contains(node)
                        ? worldTransform(of: node) * (matrices[safe: position] ?? matrix_identity_float4x4) : nil
                }
                var shape = matrix_identity_float4x4
                if let first = shapes.first, shapes.allSatisfy({ Self.same($0, first) }), abs(first.determinant) > 1e-12 {
                    shape = first
                }
                let toSkeleton = undoPlacement * shape
                vertexTransforms[index] = toSkeleton
                let undo = toSkeleton.inverse
                for (position, node) in skin.joints.enumerated() {
                    guard let joint = rig.jointOfNode[node], inverseBinds[joint] == nil else { continue }
                    inverseBinds[joint] = (matrices[safe: position] ?? matrix_identity_float4x4) * undo
                }
            }
            skeleton = try Skeleton(jointPaths: rig.paths, restTransforms: local,
                                    inverseBindTransforms: inverseBinds.enumerated().map { $1 ?? modelRest[$0].inverse })
            joints = rig
        } else if let animated = animatedJoints() {
            joints = makeJoints(animated)
        }

        var clips: [AnimationClip] = [], dropped: [(clip: String, reason: String)] = []
        if let joints {
            for (index, animation) in (document.animations ?? []).enumerated() {
                let name = animation.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Animation \(index + 1)"
                do {
                    if let clip = try makeClip(animation, name: name, joints: joints) { clips.append(clip) }
                } catch let problem as ClipProblem {
                    dropped.append((name, problem.reason))
                }
            }
        }

        var meshes: [ImportedMesh] = [], influences: [[Influence]] = []
        var materials: [ImportedMaterial] = []
        if withMeshes, let skeleton, let joints {
            materials = (document.materials ?? []).map(material)
            for node in sceneOrder {
                guard let meshIndex = nodes[node].mesh, let mesh = document.meshes?[safe: meshIndex] else { continue }
                if let skinIndex = nodes[node].skin, let skin = skins[safe: skinIndex] {
                    let remap = skin.joints.map { joints.jointOfNode[$0].map(UInt16.init) ?? 0 }
                    guard let made = try makeMesh(mesh, node: node, materialCount: materials.count, skin: remap),
                          made.influences.count == made.mesh.positions.count else { continue }
                    meshes.append(Self.placed(made.mesh, by: vertexTransforms[skinIndex] ?? matrix_identity_float4x4))
                    influences.append(made.influences)
                } else if let jointNode = ancestry(of: node).dropLast().last(where: { joints.jointOfNode[$0] != nil }),
                          let joint = joints.jointOfNode[jointNode],
                          let made = try makeMesh(mesh, node: node, materialCount: materials.count) {
                    // Hung under a joint: taken into skeleton space where it stands, then back by the joint's bind, so
                    // the joint's skinning matrix carries it from there — the identity at rest.
                    let bind = skeleton.inverseBindTransforms[joint].inverse
                    let standing = joints.nodeTransform.inverse * worldTransform(of: node)
                    let atRest = joints.nodeTransform.inverse * worldTransform(of: jointNode)
                    meshes.append(Self.placed(made, by: bind * atRest.inverse * standing))
                    influences.append(Array(repeating: Influence(joints: SIMD4(UInt16(joint), 0, 0, 0),
                                                                 weights: SIMD4(1, 0, 0, 0)),
                                            count: made.positions.count))
                }
            }
            for path in images.missing { report?("\(file): the image \(path) could not be read") }
        }
        return GLTFCharacter(skeleton: skeleton, nodeTransform: joints?.nodeTransform ?? matrix_identity_float4x4,
                             clips: clips, droppedClips: dropped, model: ImportedModel(meshes: meshes, materials: materials),
                             influences: influences)
    }

    /// A mesh's vertices moved by `m`, its normals turned with them, standing at the origin.
    static func placed(_ mesh: ImportedMesh, by m: simd_float4x4) -> ImportedMesh {
        var mesh = mesh
        mesh.transform = matrix_identity_float4x4
        guard m != matrix_identity_float4x4 else { return mesh }
        let upper = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                  SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                  SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let normalMatrix = upper.inverse.transpose
        mesh.positions = mesh.positions.map { let p = m * SIMD4($0, 1); return SIMD3(p.x, p.y, p.z) }
        mesh.normals = mesh.normals.map { simd_length($0) > 0 ? simd_normalize(normalMatrix * $0) : $0 }
        return mesh
    }

    // MARK: Joints

    /// Every node any skin names, parent first: the skins' own order when it already is, the scene's otherwise.
    func skinJoints(_ skins: [Document.Skin]) -> [Int]? {
        var ordered: [Int] = [], seen = Set<Int>()
        for skin in skins {
            for node in skin.joints where nodes.indices.contains(node) && seen.insert(node).inserted { ordered.append(node) }
        }
        guard !ordered.isEmpty else { return nil }
        return parentFirst(ordered) ? ordered : sceneOrdered(seen)
    }

    /// For a file with no skin: the nodes its animations move, and any node between two of them, so a clip still
    /// names its joints by the paths the same rig's skinned file gives them.
    func animatedJoints() -> [Int]? {
        let moved = Set((document.animations ?? []).flatMap { animation in
            animation.channels.compactMap { channel -> Int? in
                ["translation", "rotation", "scale"].contains(channel.target.path) ? channel.target.node : nil
            }
        }.filter { nodes.indices.contains($0) })
        guard !moved.isEmpty else { return nil }
        var joints = moved
        for node in moved {
            var between: [Int] = [], at = parents[node]
            while let above = at, !moved.contains(above) { between.append(above); at = parents[above] }
            if at != nil { joints.formUnion(between) }
        }
        return sceneOrdered(joints)
    }

    func sceneOrdered(_ set: Set<Int>) -> [Int] {
        sceneOrder.filter { set.contains($0) } + set.subtracting(sceneOrder).sorted()
    }

    func nearestJoint(above node: Int, in jointOfNode: [Int: Int]) -> Int? {
        var at = parents[node]
        while let above = at {
            if let joint = jointOfNode[above] { return joint }
            at = parents[above]
        }
        return nil
    }

    func parentFirst(_ ordered: [Int]) -> Bool {
        var position: [Int: Int] = [:]
        for (index, node) in ordered.enumerated() { position[node] = index }
        return ordered.enumerated().allSatisfy { index, node in
            nearestJoint(above: node, in: position).map { $0 < index } ?? true
        }
    }

    func makeJoints(_ ordered: [Int]) -> Joints {
        var jointOfNode: [Int: Int] = [:]
        for (joint, node) in ordered.enumerated() { jointOfNode[node] = joint }
        let placement = parents[ordered[0]].map(worldTransform(of:)) ?? matrix_identity_float4x4
        var paths: [String] = [], between: [simd_float4x4] = [], rest: [JointTransform] = []
        var taken = Set<String>()
        for node in ordered {
            // Up to the nearest ancestor that is a joint, gathering what lies between.
            var prefix = matrix_identity_float4x4
            var ancestor = parents[node]
            while let above = ancestor, jointOfNode[above] == nil {
                prefix = TRS(nodes[above]).matrix * prefix
                ancestor = parents[above]
            }
            let parentPath = ancestor.flatMap { jointOfNode[$0] }.map { paths[$0] }
            if parentPath == nil { prefix = placement.inverse * prefix }
            var name = (nodes[node].name ?? "").replacingOccurrences(of: "/", with: "_")
            if name.isEmpty { name = "joint\(node)" }
            var path = parentPath.map { "\($0)/\(name)" } ?? name
            // Two siblings with one name would be one path, and the second would lose its parent.
            if taken.contains(path) { path += "_\(node)" }
            taken.insert(path)
            paths.append(path)
            between.append(Self.same(prefix, matrix_identity_float4x4) ? matrix_identity_float4x4 : prefix)
            let trs = TRS(nodes[node])
            rest.append(trs.written.map(JointTransform.init(matrix:))
                        ?? JointTransform(translation: trs.translation, rotation: trs.rotation, scale: trs.scale))
        }
        return Joints(paths: paths, jointOfNode: jointOfNode, nodeOfJoint: ordered, nodeTransform: placement,
                      between: between, rest: rest)
    }

    // MARK: Influences

    /// A primitive's influences, its joints as the skeleton's — from `JOINTS_0`/`WEIGHTS_0`, and `JOINTS_1`/`WEIGHTS_1`
    /// when there are eight, keeping the four strongest. A primitive with none follows the first joint.
    func influences(_ source: PrimitiveSource, count: Int, remap: [UInt16]) throws -> [Influence] {
        guard source.has("JOINTS_0"), source.has("WEIGHTS_0") else {
            return Array(repeating: Influence(joints: SIMD4(remap.first ?? 0, 0, 0, 0), weights: SIMD4(1, 0, 0, 0)),
                         count: count)
        }
        var sets = [(try source.floats("JOINTS_0", components: 4, rawIntegers: true),
                     try source.floats("WEIGHTS_0", components: 4))]
        if source.has("JOINTS_1"), source.has("WEIGHTS_1") {
            sets.append((try source.floats("JOINTS_1", components: 4, rawIntegers: true),
                         try source.floats("WEIGHTS_1", components: 4)))
        }
        guard sets.allSatisfy({ $0.0.count == count && $0.1.count == count }) else { throw GLTFError.unreadable(file: file) }
        return try (0..<count).map { vertex in
            var lanes: [(joint: UInt16, weight: Float)] = []
            for (joints, weights) in sets {
                for lane in 0..<4 where weights[vertex][lane] > 0 {
                    let index = Int(joints[vertex][lane])
                    guard index >= 0, index < remap.count else { throw GLTFError.unreadable(file: file) }
                    lanes.append((remap[index], weights[vertex][lane]))
                }
            }
            if lanes.count > 4 { lanes = Array(lanes.sorted { $0.weight > $1.weight }.prefix(4)) }
            var influence = Influence(joints: .zero, weights: .zero)
            for (lane, value) in lanes.enumerated() {
                influence.joints[lane] = value.joint
                influence.weights[lane] = value.weight
            }
            let sum = influence.weights.sum()
            // A vertex weighted to nothing follows the first joint rather than collapsing to the origin.
            influence.weights = sum > 1e-6 ? influence.weights / sum : SIMD4(1, 0, 0, 0)
            if sum <= 1e-6 { influence.joints = SIMD4(remap.first ?? 0, 0, 0, 0) }
            return influence
        }
    }

    // MARK: Clips

    struct ClipProblem: Error { let reason: String }

    /// One glTF animation as a clip over the joints it moves, or nil when it moves none of them — morph weights alone,
    /// or nodes that are not joints. Throws ``ClipProblem`` for a clip whose data cannot be trusted.
    func makeClip(_ animation: Document.Animation, name: String, joints: Joints) throws -> AnimationClip? {
        struct Track {
            let times: [Float]
            let values: [[Float]]
            let interpolation: String

            /// The last key at or before `time` — strictly before, for the instant a step changes.
            func key(atOrBefore time: Float, strictly: Bool) -> Int {
                var low = 0, high = times.count - 1
                if strictly ? times[0] >= time : times[0] > time { return 0 }
                while low < high {
                    let mid = (low + high + 1) / 2
                    if strictly ? times[mid] < time : times[mid] <= time { low = mid } else { high = mid - 1 }
                }
                return low
            }

            func value(_ key: Int) -> [Float] { values[interpolation == "CUBICSPLINE" ? key * 3 + 1 : key] }

            func sample(at time: Float, before: Bool) -> [Float] {
                if interpolation == "STEP" { return value(key(atOrBefore: time, strictly: before)) }
                let previous = key(atOrBefore: time, strictly: false)
                guard previous < times.count - 1, time > times[previous] else { return value(previous) }
                let next = previous + 1
                let span = times[next] - times[previous]
                let s = span > 0 ? (time - times[previous]) / span : 0
                let a = value(previous), b = value(next)
                if interpolation == "CUBICSPLINE" {
                    // Hermite, with the out-tangent of one key and the in-tangent of the next.
                    let m0 = values[previous * 3 + 2], m1 = values[next * 3]
                    let s2 = s * s, s3 = s2 * s
                    return (0..<a.count).map { c in
                        (2 * s3 - 3 * s2 + 1) * a[c] + (s3 - 2 * s2 + s) * span * m0[c]
                            + (-2 * s3 + 3 * s2) * b[c] + (s3 - s2) * span * m1[c]
                    }
                }
                if a.count == 4 {
                    let q = simd_slerp(simd_quatf(vector: SIMD4(a[0], a[1], a[2], a[3])),
                                       simd_quatf(vector: SIMD4(b[0], b[1], b[2], b[3])), s)
                    return [q.vector.x, q.vector.y, q.vector.z, q.vector.w]
                }
                return zip(a, b).map { $0 + ($1 - $0) * s }
            }
        }

        var tracks: [String: [Int: Track]] = [:]
        for channel in animation.channels {
            let path = channel.target.path
            guard let node = channel.target.node, let joint = joints.jointOfNode[node],
                  ["translation", "rotation", "scale"].contains(path) else { continue }
            guard let sampler = animation.samplers[safe: channel.sampler] else {
                throw ClipProblem(reason: "a channel names a sampler the clip does not have")
            }
            let interpolation = sampler.interpolation ?? "LINEAR"
            guard ["LINEAR", "STEP", "CUBICSPLINE"].contains(interpolation) else {
                throw ClipProblem(reason: "its interpolation \(interpolation) is not one glTF defines")
            }
            let times: [Float], values: [[Float]]
            do {
                times = try readFloats(sampler.input, components: 1).map { $0[0] }
                values = try readFloats(sampler.output, components: path == "rotation" ? 4 : 3)
            } catch {
                throw ClipProblem(reason: "its keys could not be read")
            }
            guard !times.isEmpty, values.count == times.count * (interpolation == "CUBICSPLINE" ? 3 : 1) else {
                throw ClipProblem(reason: "\(joints.paths[joint]) has \(times.count) key times and \(values.count) values")
            }
            for (key, time) in times.enumerated() {
                guard time.isFinite, key == 0 || time >= times[key - 1] else {
                    throw ClipProblem(reason: "\(joints.paths[joint])'s key times are not in order")
                }
            }
            tracks[path, default: [:]][joint] = Track(times: times, values: values, interpolation: interpolation)
        }
        let all = tracks.values.flatMap(\.values)
        guard !all.isEmpty else { return nil }

        // Every key any channel has; the instant before each step, so it stays a step; and thirty a second through a
        // cubic curve, which bends between its keys where the engine's clips go straight.
        var times = Set(all.flatMap(\.times))
        let start = times.min()!, end = times.max()!
        if all.contains(where: { $0.interpolation == "CUBICSPLINE" }), end > start {
            let steps = Int(((end - start) * 30).rounded(.up))
            for step in 0...steps { times.insert(start + (end - start) * Float(step) / Float(steps)) }
        }
        let steps = Set(all.filter { $0.interpolation == "STEP" }.flatMap { $0.times.dropFirst() })
        var keys: [(time: Float, before: Bool)] = []
        for time in times.sorted() {
            if steps.contains(time) { keys.append((time, true)) }
            keys.append((time, false))
        }

        let clipJoints = Set(all.isEmpty ? [] : tracks.values.flatMap(\.keys)).sorted()
        let folded = clipJoints.contains { joints.between[$0] != matrix_identity_float4x4 }
        var poses: [[JointTransform]] = []
        for key in keys {
            poses.append(clipJoints.map { joint in
                var t = joints.rest[joint]
                if let v = tracks["translation"]?[joint]?.sample(at: key.time, before: key.before) {
                    t.translation = SIMD3(v[0], v[1], v[2])
                }
                if let v = tracks["rotation"]?[joint]?.sample(at: key.time, before: key.before) {
                    let q = simd_quatf(vector: SIMD4(v[0], v[1], v[2], v[3]))
                    t.rotation = simd_length(q.vector) > 0 ? simd_normalize(q) : joints.rest[joint].rotation
                }
                if let v = tracks["scale"]?[joint]?.sample(at: key.time, before: key.before) {
                    t.scale = SIMD3(v[0], v[1], v[2])
                }
                // What lies above a joint that is not a joint still moves it; almost always nothing does.
                let between = joints.between[joint]
                return between == matrix_identity_float4x4 ? t : JointTransform(matrix: between * t.matrix)
            })
        }
        let keyTimes = keys.map { $0.time - start }
        func track<V>(_ channel: String, _ value: (JointTransform) -> V) throws -> JointTrack<V> {
            guard folded || tracks[channel] != nil else { return .empty(jointCount: clipJoints.count) }
            return try JointTrack(times: keyTimes, values: poses.flatMap { $0.map(value) }, jointCount: clipJoints.count)
        }
        do {
            return try AnimationClip(name: name, jointPaths: clipJoints.map { joints.paths[$0] },
                                     translation: track("translation", \.translation),
                                     rotation: track("rotation", \.rotation),
                                     scale: track("scale", \.scale))
        } catch {
            throw ClipProblem(reason: "\(error)")
        }
    }
}

/// Images decoded while a document is read, and those that could not be.
private nonisolated final class ImageCache {
    var textures: [Int: ImportedTexture] = [:]
    var failed: Set<Int> = []
    var missing: [String] = []
}

// MARK: Draco

/// A primitive's vertex data, from its accessors or from its Draco-compressed buffer view.
///
/// **KHR_draco_mesh_compression replaces a primitive's accessors' data, not their meaning**: the
/// accessors still say how many values and what type, but the values come out of one decoded mesh,
/// matched to glTF attributes by the unique ids the extension lists. An attribute the extension does not
/// list is read from its accessor as usual.
private nonisolated struct PrimitiveSource {
    let primitive: Document.Primitive
    let reader: Reader
    private let draco: DecodedDraco?

    init(_ primitive: Document.Primitive, reader: Reader) throws {
        self.primitive = primitive
        self.reader = reader
        if let ext = primitive.extensions?.draco {
            let length = reader.document.bufferViews?[safe: ext.bufferView]?.byteLength ?? 0
            let (data, start, _) = try reader.bytes(view: ext.bufferView, byteOffset: 0, elementSize: 1, count: length)
            guard let decoded = DecodedDraco(data.subdata(in: start..<start + length), attributes: ext.attributes) else {
                throw GLTFError.unreadable(file: reader.file)
            }
            draco = decoded
        } else {
            draco = nil
        }
    }

    func has(_ name: String) -> Bool { primitive.attributes[name] != nil }

    /// Components per element the file declares for an attribute — 3 or 4 for a colour.
    func components(_ name: String) -> Int? {
        primitive.attributes[name].flatMap { reader.document.accessors?[safe: $0] }
            .flatMap { Document.Accessor.components[$0.type] }
    }

    func floats(_ name: String, components: Int, rawIntegers: Bool = false) throws -> [[Float]] {
        if let draco, let id = draco.attributes[name] {
            guard let values = draco.floats(id, components: components) else {
                throw GLTFError.unreadable(file: reader.file)
            }
            return values
        }
        guard let accessor = primitive.attributes[name] else { throw GLTFError.unreadable(file: reader.file) }
        return try reader.readFloats(accessor, components: components, rawIntegers: rawIntegers)
    }

    func indices() throws -> [UInt32]? {
        if let draco { return draco.indices }
        return try primitive.indices.map { try reader.readIndices($0) }
    }
}

/// One Draco mesh, decoded by Google's reference decoder and copied out into Swift values at once.
private nonisolated final class DecodedDraco {
    let attributes: [String: UInt32]
    let indices: [UInt32]
    private let mesh: OpaquePointer
    private let points: Int

    init?(_ data: Data, attributes: [String: UInt32]) {
        guard let mesh = data.withUnsafeBytes({ raw in raw.baseAddress.flatMap { du_draco_decode($0, raw.count) } }) else {
            return nil
        }
        self.mesh = mesh
        self.attributes = attributes
        points = Int(du_draco_point_count(mesh))
        var indices = [UInt32](repeating: 0, count: Int(du_draco_face_count(mesh)) * 3)
        indices.withUnsafeMutableBufferPointer { du_draco_indices(mesh, $0.baseAddress!) }
        self.indices = indices
    }

    deinit { du_draco_free(mesh) }

    /// An attribute as `components` floats per point, padding or truncating what Draco stores.
    func floats(_ id: UInt32, components: Int) -> [[Float]]? {
        let stored = Int(du_draco_attribute_components(mesh, id))
        guard stored > 0 else { return nil }
        var flat = [Float](repeating: 0, count: points * stored)
        let ok = flat.withUnsafeMutableBufferPointer { du_draco_attribute_floats(mesh, id, $0.baseAddress!) }
        guard ok != 0 else { return nil }
        return (0..<points).map { p in (0..<components).map { c in c < stored ? flat[p * stored + c] : 0 } }
    }
}

// MARK: Transforms

/// A node's translation, rotation and scale — glTF's own way of writing a transform.
private nonisolated struct TRS: Equatable {
    var translation = SIMD3<Float>.zero
    var rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var scale = SIMD3<Float>(repeating: 1)
    /// A node written as a matrix is kept as one: pulling it apart and putting it back together is exact
    /// only for a matrix with no shear.
    var written: simd_float4x4?

    init(_ node: Document.Node) {
        if let m = node.matrix, m.count == 16 {
            written = simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                              SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
            return
        }
        if let t = node.translation, t.count == 3 { translation = SIMD3(t[0], t[1], t[2]) }
        if let r = node.rotation, r.count == 4 { rotation = simd_normalize(simd_quatf(vector: SIMD4(r[0], r[1], r[2], r[3]))) }
        if let s = node.scale, s.count == 3 { scale = SIMD3(s[0], s[1], s[2]) }
    }

    var matrix: simd_float4x4 {
        if let written { return written }
        var m = simd_float4x4(rotation)
        m.columns.0 *= scale.x
        m.columns.1 *= scale.y
        m.columns.2 *= scale.z
        m.columns.3 = SIMD4(translation, 1)
        return m
    }
}

// MARK: The schema

/// As much of glTF 2.0's JSON as is read here. Everything else in a file is ignored by the decoder.
private nonisolated struct Document: Decodable {
    let asset: Asset
    let extensionsRequired: [String]?
    let scene: Int?
    let scenes: [Scene]?
    let nodes: [Node]?
    let meshes: [Mesh]?
    let materials: [Material]?
    let textures: [Texture]?
    let samplers: [Sampler]?
    let images: [Image]?
    let skins: [Skin]?
    let animations: [Animation]?
    let accessors: [Accessor]?
    let bufferViews: [BufferView]?
    let buffers: [Buffer]?

    struct Asset: Decodable { let version: String }
    struct Scene: Decodable { let nodes: [Int]? }
    struct Node: Decodable {
        let name: String?
        let children: [Int]?
        let mesh: Int?
        let skin: Int?
        let matrix: [Float]?
        let translation: [Float]?
        let rotation: [Float]?
        let scale: [Float]?
    }
    struct Mesh: Decodable {
        let name: String?
        let primitives: [Primitive]
    }
    struct Primitive: Decodable {
        let attributes: [String: Int]
        let indices: Int?
        let material: Int?
        let mode: Int?
        let extensions: Extensions?

        struct Extensions: Decodable {
            let draco: Draco?
            enum CodingKeys: String, CodingKey { case draco = "KHR_draco_mesh_compression" }
        }
        /// The buffer view holding the compressed mesh, and each glTF attribute's Draco unique id.
        struct Draco: Decodable {
            let bufferView: Int
            let attributes: [String: UInt32]
        }
    }
    struct Material: Decodable {
        let name: String?
        let pbrMetallicRoughness: PBR?
        let normalTexture: TextureInfo?
        let occlusionTexture: TextureInfo?
        let emissiveTexture: TextureInfo?
        let emissiveFactor: [Float]?
        let alphaMode: String?
        let alphaCutoff: Float?
        let doubleSided: Bool?
        let extensions: Extensions?

        struct PBR: Decodable {
            let baseColorFactor: [Float]?
            let baseColorTexture: TextureInfo?
            let metallicFactor: Float?
            let roughnessFactor: Float?
            let metallicRoughnessTexture: TextureInfo?
        }
        struct Extensions: Decodable {
            let emissiveStrength: EmissiveStrength?
            enum CodingKeys: String, CodingKey { case emissiveStrength = "KHR_materials_emissive_strength" }
            struct EmissiveStrength: Decodable { let emissiveStrength: Float? }
        }
    }
    /// A texture as a material names it. `scale` is a normal map's, `strength` an occlusion map's.
    struct TextureInfo: Decodable {
        let index: Int
        let texCoord: Int?
        let scale: Float?
        let strength: Float?
        let extensions: Extensions?

        struct Extensions: Decodable {
            let transform: Transform?
            enum CodingKeys: String, CodingKey { case transform = "KHR_texture_transform" }
        }
        struct Transform: Decodable {
            let offset: [Float]?
            let rotation: Float?
            let scale: [Float]?
            let texCoord: Int?
        }
    }
    struct Texture: Decodable {
        let source: Int?
        let sampler: Int?
        let extensions: Extensions?
        struct Extensions: Decodable {
            let webp: Source?
            /// A KTX2 image with Basis Universal data, preferred over any PNG or JPEG fallback beside it.
            let basisu: Source?
            enum CodingKeys: String, CodingKey { case webp = "EXT_texture_webp", basisu = "KHR_texture_basisu" }
            struct Source: Decodable { let source: Int? }
        }
    }
    struct Sampler: Decodable { let magFilter: Int?; let minFilter: Int?; let wrapS: Int?; let wrapT: Int? }
    struct Image: Decodable { let uri: String?; let bufferView: Int?; let mimeType: String?; let name: String? }
    struct Skin: Decodable { let inverseBindMatrices: Int?; let joints: [Int] }
    struct Animation: Decodable {
        let name: String?
        let channels: [Channel]
        let samplers: [Sampler]
        struct Channel: Decodable {
            let sampler: Int
            let target: Target
            struct Target: Decodable { let node: Int?; let path: String }
        }
        struct Sampler: Decodable { let input: Int; let output: Int; let interpolation: String? }
    }
    struct Accessor: Decodable {
        let bufferView: Int?
        let byteOffset: Int?
        let componentType: Int
        let normalized: Bool?
        let count: Int
        let type: String
        let sparse: Sparse?

        struct Sparse: Decodable {
            let count: Int
            let indices: Indices
            let values: Values
            struct Indices: Decodable { let bufferView: Int; let byteOffset: Int?; let componentType: Int }
            struct Values: Decodable { let bufferView: Int; let byteOffset: Int? }
        }

        static let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16]

        var componentSize: Int {
            switch componentType {
            case 5120, 5121: 1
            case 5122, 5123: 2
            default: 4
            }
        }
    }
    struct BufferView: Decodable {
        let buffer: Int
        let byteOffset: Int?
        let byteLength: Int
        let byteStride: Int?
        let extensions: Extensions?

        struct Extensions: Decodable {
            let ext: Meshopt?
            let khr: Meshopt?
            /// Either name: the Khronos extension is the EXT one with a newer attribute encoding, which
            /// the decoder reads by its header byte.
            var meshopt: Meshopt? { khr ?? ext }
            enum CodingKeys: String, CodingKey {
                case ext = "EXT_meshopt_compression", khr = "KHR_meshopt_compression"
            }
        }
        struct Meshopt: Decodable {
            let buffer: Int
            let byteOffset: Int?
            let byteLength: Int
            let byteStride: Int
            let count: Int
            let mode: String
            let filter: String?
        }
    }
    struct Buffer: Decodable { let uri: String?; let byteLength: Int }
}

private extension Data {
    nonisolated func word(at offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}

private extension Array {
    nonisolated subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
