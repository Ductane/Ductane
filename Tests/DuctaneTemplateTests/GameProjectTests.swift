//
//  GameProjectTests.swift
//  DuctaneTemplateTests
//

import Foundation
import Testing
@testable import DuctaneTemplate

@Suite struct GameProjectTests {

    private func project(_ name: String = "Marsh Walk", organization: String = "com.example",
                         engine: GameProject.Engine = .release(from: "1.5.0")) -> GameProject {
        GameProject(name: name, organization: organization, engine: engine)
    }

    @Test func aNameBecomesATargetName() {
        #expect(GameProject.targetName(from: "Marsh Walk") == "MarshWalk")
        #expect(GameProject.targetName(from: "3 Kings") == "Kings")
        #expect(GameProject.targetName(from: "Ice-bound!") == "Icebound")
        #expect(GameProject.targetName(from: "my_game 2") == "my_game2")
        #expect(GameProject.targetName(from: "Café") == "Caf")
        #expect(GameProject.targetName(from: "123") == "")
        #expect(GameProject.targetName(from: "  ") == "")
    }

    @Test func theBundleIdentifierJoinsTheOrganizationAndTheTarget() {
        #expect(project().bundleIdentifier == "com.example.MarshWalk")
        #expect(project().projectFile == "MarshWalk.xcodeproj")
    }

    @Test func organizationsAreReverseDNS() {
        #expect(GameProject.isValidOrganization("com.example"))
        #expect(GameProject.isValidOrganization("io.my-studio"))
        #expect(GameProject.isValidOrganization("studio"))
        #expect(!GameProject.isValidOrganization(""))
        #expect(!GameProject.isValidOrganization("com..example"))
        #expect(!GameProject.isValidOrganization("com.example."))
        #expect(!GameProject.isValidOrganization("com.ex ample"))
        #expect(!GameProject.isValidOrganization("com.exämple"))
    }

    @Test func aProblemIsSaidBeforeAnythingIsWritten() {
        #expect(project().problem == nil)
        #expect(project("").problem != nil)
        #expect(project("42").problem != nil)
        #expect(project(organization: "com example").problem != nil)
        #expect(project(engine: .release(from: "1.5")).problem != nil)
        #expect(project(engine: .local(path: "")).problem != nil)
        #expect(project("Line\nBreak").problem != nil)
    }

    @Test func theProjectHasItsFiles() {
        let paths = project().files().map(\.path)
        #expect(paths.contains("MarshWalk.xcodeproj/project.pbxproj"))
        #expect(paths.contains("MarshWalk.xcodeproj/xcshareddata/xcschemes/MarshWalk.xcscheme"))
        #expect(paths.contains("MarshWalk/main.swift"))
        #expect(paths.contains("MarshWalk/Game.swift"))
        #expect(paths.contains("MarshWalk/GameView.swift"))
        #expect(paths.contains("Worlds/README.md"))
        #expect(paths.contains("Info.plist"), "the game says it opens scene packages")
        // Every placeholder is filled in.
        for (path, contents) in project().files() { #expect(!contents.contains("{{"), "\(path)") }
    }

    @Test func aReleaseIsFetchedFromGitHubFromItsVersion() throws {
        let pbxproj = try #require(project().files().first { $0.path.hasSuffix("project.pbxproj") }?.contents)
        #expect(pbxproj.contains("isa = XCRemoteSwiftPackageReference;"))
        #expect(pbxproj.contains("repositoryURL = \"https://github.com/Ductane/Ductane.git\";"))
        #expect(pbxproj.contains("kind = upToNextMajorVersion;"))
        #expect(pbxproj.contains("minimumVersion = 1.5.0;"))
        #expect(pbxproj.contains("PRODUCT_BUNDLE_IDENTIFIER = \"com.example.MarshWalk\";"))
        #expect(pbxproj.contains("INFOPLIST_KEY_CFBundleDisplayName = \"Marsh Walk\";"))
        #expect(pbxproj.components(separatedBy: "INFOPLIST_FILE = Info.plist;").count == 3, "both configurations")
        let plist = try #require(project().files().first { $0.path == "Info.plist" }?.contents)
        #expect(plist.contains("com.pixar.universal-scene-description-mobile"))
        #expect(plist.contains("<string>Alternate</string>"), "offered, never the default")
        let main = try #require(project().files().first { $0.path.hasSuffix("main.swift") }?.contents)
        #expect(main.contains("\"\(GameProject.quitRequest)\""), "the game hears the stop button's notice")
    }

    @Test func aCheckoutIsALocalPackage() throws {
        let pbxproj = try #require(project(engine: .local(path: "../Ductane")).files()
            .first { $0.path.hasSuffix("project.pbxproj") }?.contents)
        #expect(pbxproj.contains("isa = XCLocalSwiftPackageReference;"))
        #expect(pbxproj.contains("relativePath = \"../Ductane\";"))
        #expect(!pbxproj.contains("XCRemoteSwiftPackageReference"))
    }

    @Test func aNameWithQuotesStaysInsideItsLiterals() throws {
        let files = project("The \"Last\" Walk").files()
        let main = try #require(files.first { $0.path.hasSuffix("main.swift") }?.contents)
        #expect(main.contains(#"window.title = "The \"Last\" Walk""#))
        let pbxproj = try #require(files.first { $0.path.hasSuffix("project.pbxproj") }?.contents)
        #expect(pbxproj.contains(#"INFOPLIST_KEY_CFBundleDisplayName = "The \"Last\" Walk";"#))
    }

    @Test func aNameIsNeverTakenForAPlaceholder() throws {
        let files = project("{{TARGET}} Walk").files()
        let main = try #require(files.first { $0.path.hasSuffix("main.swift") }?.contents)
        #expect(main.contains(#"window.title = "{{TARGET}} Walk""#))
    }

    @Test func writingMakesTheFolderAndRefusesOneInUse() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "GameProjectTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "MarshWalk")
        let file = try project().write(into: folder)
        #expect(file.lastPathComponent == "MarshWalk.xcodeproj")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "MarshWalk/Game.swift").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Worlds").path))
        #expect(throws: GameProject.WriteError.notEmpty("MarshWalk")) { try project().write(into: folder) }
        // An empty folder, as a save panel may have made, is fine.
        let empty = parent.appending(path: "Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try project().write(into: empty)
        #expect(throws: GameProject.WriteError.invalid("Give the game a name.")) {
            try project("").write(into: parent.appending(path: "Nameless"))
        }
    }
}
