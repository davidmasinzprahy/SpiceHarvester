import Testing
import Foundation
@testable import SpiceHarvester

struct SHAppDelegateTests {
    @Test func fileKindClassifiesBySuffix() {
        #expect(SHAppDelegate.fileKind(for: URL(fileURLWithPath: "/x/a.spiceharvester.json")) == .project)
        #expect(SHAppDelegate.fileKind(for: URL(fileURLWithPath: "/x/a.spice-result.json")) == .result)
        #expect(SHAppDelegate.fileKind(for: URL(fileURLWithPath: "/x/a.json")) == .unsupported)
        #expect(SHAppDelegate.fileKind(for: URL(fileURLWithPath: "/x/a.pdf")) == .unsupported)
        // Dvojitá přípona se nesmí splést s jednoduchou (regrese na opravený bug,
        // kde se matchovalo přes url.pathExtension == "spice-result.json").
        #expect(SHAppDelegate.fileKind(for: URL(fileURLWithPath: "/x/report.spice-result.json")) == .result)
    }
}
