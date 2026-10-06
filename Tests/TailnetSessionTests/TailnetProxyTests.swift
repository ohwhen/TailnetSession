import Foundation
import Testing
import WebKit
@testable import TailnetSession

private let proxy = TailnetProxy(host: "127.0.0.1", port: 1055, username: "tsnet", password: "secret")

struct TailnetProxyTests {
    @Test func republishingTheSameProxyStillBumpsTheEpoch() {
        let store = TailnetProxyStore()
        store.set(proxy)
        let first = store.snapshot
        store.set(proxy)
        #expect(store.snapshot.proxy == first.proxy)
        #expect(store.snapshot.epoch == first.epoch + 1)
        store.set(nil)
        #expect(store.current == nil)
        #expect(store.snapshot.epoch == first.epoch + 2)
    }

    @Test func waitingReturnsTheProxyOnceANodePublishesIt() async {
        let store = TailnetProxyStore()
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            store.set(proxy)
        }
        #expect(await store.waitUntilReady(timeout: .seconds(5)) == proxy)
    }

    @Test func waitingGivesUpAtTheTimeout() async {
        #expect(await TailnetProxyStore().waitUntilReady(timeout: .milliseconds(300)) == nil)
    }

    @Test func aSessionConfigurationRoutesThroughTheProxy() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.route(through: proxy)
        #expect(configuration.proxyConfigurations.count == 1)
    }

    @MainActor
    @Test func aTailnetWebsiteStoreIsNonPersistentAndProxied() {
        let store = WKWebsiteDataStore.tailnet(proxy)
        #expect(!store.isPersistent)
        #expect(store.proxyConfigurations.count == 1)
        #expect(WKWebsiteDataStore.default().proxyConfigurations.isEmpty)
    }

    @Test func theDefaultStateDirectoryLivesInApplicationSupport() {
        #expect(Tailnet.defaultStateDirectory.lastPathComponent == "Tailnet")
        #expect(Tailnet.defaultStateDirectory.path().hasPrefix(URL.applicationSupportDirectory.path()))
    }
}
