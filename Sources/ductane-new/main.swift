//
//  main.swift
//  ductane-new
//
//  **A new game, ready to run**: `swift run ductane-new "My Game"` writes a small Xcode project that opens a scene
//  package, draws it with `WorldRenderer`, walks it and plays its sounds (`GameProject`).
//

import Foundation
import Ductane
import DuctaneTemplate

let usage = """
    usage: ductane-new <game name> [--organization com.example] [--into <folder>] [--engine-path <path>]

      --organization   the start of the bundle identifier (default com.example)
      --into           the folder the project's folder is made in (default the current one)
      --engine-path    use a Ductane checkout at this path instead of the release on GitHub

    """

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard arguments.indices.contains(index + 1) else {
        FileHandle.standardError.write(Data("ductane-new: \(name) needs a value\n\(usage)".utf8))
        exit(2)
    }
    defer { arguments.removeSubrange(index...(index + 1)) }
    return arguments[index + 1]
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(usage, terminator: "")
    exit(0)
}
let organization = option("--organization") ?? "com.example"
let parent = URL(filePath: option("--into") ?? FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
let enginePath = option("--engine-path")
guard arguments.count == 1, let name = arguments.first, !name.hasPrefix("-") else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

var project = GameProject(name: name, organization: organization,
                          engine: .release(from: Engine.semanticVersion.description))
if let enginePath {
    // A relative path is taken from where the command was run, and written relative to the project's folder.
    let engine = URL(filePath: enginePath, directoryHint: .isDirectory,
                     relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
    project.engine = .local(path: engine.standardizedFileURL.path)
}
let folder = parent.appending(path: project.targetName, directoryHint: .isDirectory)
do {
    let file = try project.write(into: folder)
    print("""
        Made \(project.name) in \(folder.path)
          bundle identifier \(project.bundleIdentifier)

        Next: export a scene package into \(folder.appending(path: GameProject.worldsFolder).path),
        then open \(file.lastPathComponent) and press Run.
        """)
} catch {
    FileHandle.standardError.write(Data("ductane-new: \(error.localizedDescription)\n".utf8))
    exit(1)
}
