import Foundation
import Testing
@testable import SpiceHarvester

@Suite struct SHToolingTests {
    @Test func toolExecutableNamesAndVersionArgs() {
        #expect(SHTool.pandoc.executableName == "pandoc")
        #expect(SHTool.pdftotext.executableName == "pdftotext")
        #expect(SHTool.pdfinfo.executableName == "pdfinfo")
        #expect(SHTool.pandoc.versionArguments == ["--version"])
    }

    @Test func runtimeResolvesFromHelpersThenPath() throws {
        let fm = FileManager.default
        let helpers = fm.temporaryDirectory.appendingPathComponent("helpers-\(UUID().uuidString)")
        let pathDir = fm.temporaryDirectory.appendingPathComponent("path-\(UUID().uuidString)")
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        try fm.createDirectory(at: pathDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: helpers); try? fm.removeItem(at: pathDir) }

        // jen v PATH
        let inPath = pathDir.appendingPathComponent("pdfinfo")
        fm.createFile(atPath: inPath.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        // v helpers i PATH -> vyhrává helpers
        let inHelpers = helpers.appendingPathComponent("pandoc")
        fm.createFile(atPath: inHelpers.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let inPathPandoc = pathDir.appendingPathComponent("pandoc")
        fm.createFile(atPath: inPathPandoc.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let runtime = SHToolRuntime(helpersDirectory: helpers, pathDirectories: [pathDir])
        #expect(runtime.resolve(.pandoc)?.path == inHelpers.path)
        #expect(runtime.resolve(.pdfinfo)?.path == inPath.path)
        #expect(runtime.resolve(.pdftotext) == nil)
    }
}
