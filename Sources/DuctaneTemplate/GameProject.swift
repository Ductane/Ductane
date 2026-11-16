//
//  GameProject.swift
//  DuctaneTemplate
//

import Foundation

/// **A new game, ready to run**: a small Xcode project that depends on Ductane, opens a scene package from its
/// `Worlds` folder, draws it with `WorldRenderer`, walks it in first person and plays its sounds.
///
/// `swift run ductane-new "My Game"` writes one; a world editor can write the same files. Nothing here needs a window
/// or a GPU, so a sandboxed app can write a project into a folder it was given.
///
/// ```swift
/// let project = GameProject(name: "Marsh Walk", organization: "com.example", engine: .release(from: "1.5.0"))
/// try project.write(into: folder.appending(path: project.targetName))
/// ```
public nonisolated struct GameProject: Sendable, Equatable {

    /// Where the project gets Ductane from.
    public enum Engine: Sendable, Equatable {
        /// The public package on GitHub, from this version up to the next major one.
        case release(from: String)
        /// A checkout at this path — relative to the project's folder, or absolute.
        case local(path: String)
    }

    /// The engine's public repository.
    public static let repository = "https://github.com/Ductane/Ductane.git"
    /// The folder, beside the code, that the game opens its worlds from. Its contents are built into the app.
    public static let worldsFolder = "Worlds"

    /// The game's name as a person wrote it — its window's title and the name under its icon.
    public var name: String
    /// The reverse-DNS prefix of its bundle identifier: `com.example`.
    public var organization: String
    public var engine: Engine

    public init(name: String, organization: String, engine: Engine) {
        self.name = name
        self.organization = organization
        self.engine = engine
    }

    /// The name as a Swift target and product: letters, digits and underscores, never starting with a digit.
    public var targetName: String { Self.targetName(from: name) }
    /// `<organization>.<targetName>`.
    public var bundleIdentifier: String { "\(organization).\(targetName)" }
    /// The project file's name, inside the project's folder.
    public var projectFile: String { "\(targetName).xcodeproj" }

    /// **A name made a valid target name**: words joined with each one's first letter kept as written, everything
    /// but letters, digits and underscores dropped, and leading digits dropped. "Marsh Walk" is `MarshWalk`, "3 Kings"
    /// is `Kings`, "Ice-bound!" is `Icebound`. Empty when nothing is left.
    public static func targetName(from name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            let ascii = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
            guard ascii else { continue }
            if result.isEmpty, CharacterSet.decimalDigits.contains(scalar) { continue }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// **Whether `organization` can begin a bundle identifier**: one or more parts joined by dots, each of ASCII
    /// letters, digits and hyphens.
    public static func isValidOrganization(_ organization: String) -> Bool {
        let parts = organization.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
        }
    }

    /// Whether `version` is `major.minor.patch`.
    static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// **What stops this project being written**, said for a person, or nil when it can be.
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the game a name." }
        if targetName.isEmpty { return "The name needs at least one letter (A to Z)." }
        if !Self.isValidOrganization(organization) {
            return "The organization identifier is reverse-DNS, like com.example: letters, digits and hyphens, joined by dots."
        }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "The name can't contain control characters."
        }
        switch engine {
        case .release(let version) where !Self.isValidVersion(version): return "The engine version \(version) isn't major.minor.patch."
        case .local(let path) where path.isEmpty || path.contains("\"") || path.contains("\\"): return "The engine's path can't be used."
        default: return nil
        }
    }

    /// **Every file of the project**, by its path inside the project's folder.
    public func files() -> [(path: String, contents: String)] {
        let target = targetName
        func fill(_ template: String) -> String {
            // The name a person wrote goes in last, so nothing in it is taken for a placeholder.
            template
                .replacingOccurrences(of: "{{TARGET}}", with: target)
                .replacingOccurrences(of: "{{BUNDLE_ID}}", with: bundleIdentifier)
                .replacingOccurrences(of: "{{ENGINE_REFERENCE_ISA}}", with: engineReferenceKind)
                .replacingOccurrences(of: "{{ENGINE_REFERENCE}}", with: engineReference)
                .replacingOccurrences(of: "{{WORLDS}}", with: Self.worldsFolder)
                .replacingOccurrences(of: "{{TITLE_SWIFT}}", with: Self.swiftLiteral(name))
                .replacingOccurrences(of: "{{TITLE_PBX}}", with: Self.pbxLiteral(name))
                .replacingOccurrences(of: "{{TITLE}}", with: name)
        }
        return [
            ("\(projectFile)/project.pbxproj", fill(ProjectTemplate.pbxproj)),
            ("\(projectFile)/project.xcworkspace/contents.xcworkspacedata", fill(ProjectTemplate.workspace)),
            ("\(projectFile)/xcshareddata/xcschemes/\(target).xcscheme", fill(ProjectTemplate.scheme)),
            ("\(target)/main.swift", fill(ProjectTemplate.main)),
            ("\(target)/Game.swift", fill(ProjectTemplate.game)),
            ("\(target)/GameView.swift", fill(ProjectTemplate.view)),
            ("\(Self.worldsFolder)/README.md", fill(ProjectTemplate.worldsReadme)),
            ("README.md", fill(ProjectTemplate.readme)),
            (".gitignore", ProjectTemplate.gitignore),
        ]
    }

    /// **Writes the project into `folder`**, which is made if it is not there and must be empty if it is. Returns the
    /// project file's URL.
    @discardableResult
    public func write(into folder: URL) throws -> URL {
        if let problem { throw WriteError.invalid(problem) }
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isFolder) {
            guard isFolder.boolValue else { throw WriteError.notAFolder(folder.path) }
            let contents = try fm.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }
            guard contents.isEmpty else { throw WriteError.notEmpty(folder.lastPathComponent) }
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, contents) in files() {
            let url = folder.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return folder.appending(path: projectFile, directoryHint: .isDirectory)
    }

    public enum WriteError: LocalizedError, Equatable {
        case invalid(String)
        case notAFolder(String)
        case notEmpty(String)
        public var errorDescription: String? {
            switch self {
            case .invalid(let problem): problem
            case .notAFolder(let path): "\(path) is a file, not a folder."
            case .notEmpty(let name): "The folder “\(name)” already has files in it. Choose a new or empty folder."
            }
        }
    }

    // MARK: Filling in

    /// The package reference's body in the project file.
    private var engineReference: String {
        switch engine {
        case .release(let version):
            """
            repositoryURL = "\(Self.repository)";
            			requirement = {
            				kind = upToNextMajorVersion;
            				minimumVersion = \(version);
            			};
            """
        case .local(let path):
            "relativePath = \"\(path)\";"
        }
    }

    private var engineReferenceKind: String {
        switch engine {
        case .release: "XCRemoteSwiftPackageReference"
        case .local: "XCLocalSwiftPackageReference"
        }
    }

    /// `text` inside a Swift string literal's quotes.
    static func swiftLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `text` as a quoted string in a project file.
    static func pbxLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
