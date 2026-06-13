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
}
