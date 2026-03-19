import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

struct AlibabaCodingPlanCookieImporterTests {
    @Test
    func domainMatchingRequiresExactOrLabelBoundedSuffix() {
        #expect(AlibabaCodingPlanCookieImporter.matchesCookieDomain("console.aliyun.com"))
        #expect(AlibabaCodingPlanCookieImporter.matchesCookieDomain(".modelstudio.console.alibabacloud.com"))
        #expect(AlibabaCodingPlanCookieImporter.matchesCookieDomain("foo.aliyun.com"))
        #expect(AlibabaCodingPlanCookieImporter.matchesCookieDomain("evilaliyun.com") == false)
        #expect(AlibabaCodingPlanCookieImporter.matchesCookieDomain("notalibabacloud.com") == false)
    }

    @Test
    func cookieImportCandidatesHonorProvidedBrowserOrder() throws {
        BrowserCookieAccessGate.resetForTesting()

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let firefoxProfile = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Firefox")
            .appendingPathComponent("Profiles")
            .appendingPathComponent("abc.default-release")
        try FileManager.default.createDirectory(at: firefoxProfile, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: firefoxProfile.appendingPathComponent("cookies.sqlite").path,
            contents: Data())

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        let importOrder: BrowserCookieImportOrder = [.firefox, .safari, .chrome]

        let candidates = AlibabaCodingPlanCookieImporter.cookieImportCandidates(
            browserDetection: detection,
            importOrder: importOrder)

        let expected: [Browser] = [.firefox, .safari]
        #expect(candidates == expected)
    }
}

#else

struct AlibabaCodingPlanCookieImporterTests {
    @Test
    func nonMacOSPlaceholder() {
        #expect(true)
    }
}

#endif
