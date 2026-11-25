import XCTest
@testable import STV

final class PerSourceDebugLogTests: XCTestCase {
    func testCMSLogClearIsScopedToOneSite() {
        let suffix = UUID().uuidString
        let siteA = "site-a-\(suffix)"
        let siteB = "site-b-\(suffix)"
        CMSLog.add(siteA, "request A")
        CMSLog.add(siteB, "request B")

        CMSLog.clear(siteA)

        XCTAssertTrue(CMSLog.lines(siteA).isEmpty)
        XCTAssertTrue(CMSLog.lines(siteB).contains { $0.contains("request B") })
        CMSLog.clear(siteB)
    }

    func testPluginLogClearIsScopedToOnePlugin() {
        let suffix = UUID().uuidString
        let pluginA = "test.plugin.a.\(suffix)"
        let pluginB = "test.plugin.b.\(suffix)"
        PluginLog.add(pluginA, "request A")
        PluginLog.add(pluginB, "request B")

        PluginLog.clear(pluginA)

        XCTAssertTrue(PluginLog.lines(pluginA).isEmpty)
        XCTAssertTrue(PluginLog.lines(pluginB).contains { $0.contains("request B") })
        PluginLog.clear(pluginB)
    }
}
