import Foundation
import Network
import os
import WebKit

/// The SOCKS5 loopback a running node exposes. Anything that dials through it reaches the tailnet.
public struct TailnetProxy: Sendable, Hashable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let password: String

    public init(host: String, port: UInt16, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public var configuration: ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        configuration.applyCredential(username: username, password: password)
        return configuration
    }
}

/// Holds the proxy of the running node, so code that builds sessions far from the node can find it.
///
/// Every `set` bumps `epoch`, including a republish of identical values after a reconnect, so a
/// client that remembers the epoch it built against knows when to rebuild.
public final class TailnetProxyStore: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let proxy: TailnetProxy?
        public let epoch: Int
    }

    public static let shared = TailnetProxyStore()

    private let state = OSAllocatedUnfairLock(initialState: Snapshot(proxy: nil, epoch: 0))

    public init() {}

    public var current: TailnetProxy? {
        state.withLock { $0.proxy }
    }

    public var snapshot: Snapshot {
        state.withLock { $0 }
    }

    public func set(_ proxy: TailnetProxy?) {
        state.withLock { $0 = Snapshot(proxy: proxy, epoch: $0.epoch + 1) }
    }

    /// Returns the proxy once a node publishes one, or nil when `timeout` passes first.
    public func waitUntilReady(timeout: Duration = .seconds(10)) async -> TailnetProxy? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let proxy = current { return proxy }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return current
    }
}

public extension URLSessionConfiguration {
    /// Sends every task of a session built from this configuration, `URLSessionWebSocketTask`
    /// included, through the tailnet.
    func route(through proxy: TailnetProxy) {
        proxyConfigurations = [proxy.configuration]
    }
}

public extension WKWebsiteDataStore {
    /// A non-persistent store that loads through the tailnet. Setting the proxy on
    /// `WKWebsiteDataStore.default()` instead would reroute every other web view in the app.
    @MainActor
    static func tailnet(_ proxy: TailnetProxy) -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy.configuration]
        return store
    }
}
