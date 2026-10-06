import Foundation
@preconcurrency import TailscaleKit

public enum TailnetLoginEvent: Sendable, Equatable {
    /// Open this URL so the user can sign in to the tailnet.
    case browseToURL(URL)
    /// The node is up and its proxy is published.
    case running
}

public enum TailnetError: Error, Equatable, LocalizedError {
    /// The persisted node could not come back without an interactive login.
    case needsLogin

    public var errorDescription: String? {
        switch self {
        case .needsLogin:
            "This device needs to sign in to the tailnet again."
        }
    }
}

/// One userspace Tailscale node inside the app: no VPN profile, no Network Extension.
///
/// `login()` signs in through the browser and `resume()` brings a signed-in node back after a
/// relaunch. Once the node runs, its SOCKS5 proxy is published to `proxyStore`; route sessions
/// through it to reach the tailnet.
public actor Tailnet {
    public struct Configuration: Sendable {
        public var hostName: String
        public var stateDirectory: URL
        public var controlURL: String

        public init(
            hostName: String,
            stateDirectory: URL = Tailnet.defaultStateDirectory,
            controlURL: String = kDefaultControlURL
        ) {
            self.hostName = hostName
            self.stateDirectory = stateDirectory
            self.controlURL = controlURL
        }
    }

    public static var defaultStateDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Tailnet", directoryHint: .isDirectory)
    }

    public nonisolated let proxyStore: TailnetProxyStore

    private let configuration: Configuration
    private let logger: (any LogSink)?
    private var node: TailscaleNode?
    private var client: LocalAPIClient?
    private var watcher: MessageProcessor?
    private var generation = 0
    private var resumeTask: Task<Void, any Error>?

    public init(configuration: Configuration, proxyStore: TailnetProxyStore = .shared, logger: (any LogSink)? = nil) {
        self.configuration = configuration
        self.proxyStore = proxyStore
        self.logger = logger
    }

    public var isRunning: Bool {
        node != nil && proxyStore.current != nil
    }

    /// Starts an interactive login. Ends after `.running`, or throws.
    ///
    /// Cancelling the task that iterates the stream abandons the login and stops the node.
    public nonisolated func login() -> AsyncThrowingStream<TailnetLoginEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.beginLogin(continuation) }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { await self.disconnect() }
            }
        }
    }

    /// Brings a previously signed-in node back up without user interaction.
    ///
    /// Concurrent calls share one attempt. Throws `TailnetError.needsLogin` when the stored
    /// session is gone or expired.
    public func resume(timeout: Duration = .seconds(20)) async throws {
        if let resumeTask {
            return try await resumeTask.value
        }
        let task = Task { try await performResume(timeout: timeout) }
        resumeTask = task
        defer { resumeTask = nil }
        try await task.value
    }

    /// Stops the node and clears the published proxy. The signed-in state stays on disk for `resume()`.
    public func disconnect() async {
        generation += 1
        await teardown()
    }

    private func beginLogin(_ continuation: AsyncThrowingStream<TailnetLoginEvent, any Error>.Continuation) async {
        generation += 1
        let attempt = generation
        await teardown()
        do {
            let client = try startNode()
            let consumer = LoginConsumer(
                continuation: continuation,
                onRunning: { [weak self] in await self?.loginReachedRunning(attempt) ?? false },
                onIdleTimeout: { [weak self] consumer in await self?.rewatch(consumer, attempt: attempt) ?? false }
            )
            watcher = try await client.watchIPNBus(mask: [.initialState, .netmap], consumer: consumer)
            try await client.start(options: Self.emptyOptions())
            _ = try? await client.editPrefs(mask: Ipn.MaskedPrefs().corpDNS(true))
            try await client.startLoginInteractive()
            guard attempt == generation else { throw CancellationError() }
        } catch {
            if attempt == generation { await teardown() }
            continuation.finish(throwing: error)
        }
    }

    private func loginReachedRunning(_ attempt: Int) async -> Bool {
        guard attempt == generation else { return false }
        do {
            try await publishProxy()
            watcher?.cancel()
            watcher = nil
            return true
        } catch {
            logger?.log("tailnet: could not publish the proxy: \(error)")
            return false
        }
    }

    private func rewatch(_ consumer: LoginConsumer, attempt: Int) async -> Bool {
        guard attempt == generation, let client else { return false }
        watcher?.cancel()
        watcher = try? await client.watchIPNBus(mask: [.initialState, .netmap], consumer: consumer)
        return watcher != nil
    }

    private func performResume(timeout: Duration) async throws {
        generation += 1
        let attempt = generation
        await teardown()
        do {
            let client = try startNode()
            let consumer = ResumeConsumer()
            watcher = try await client.watchIPNBus(mask: [.initialState, .netmap], consumer: consumer)
            try await client.start(options: Self.emptyOptions())
            _ = try await client.editPrefs(mask: Ipn.MaskedPrefs().wantRunning(true).corpDNS(true))
            let running = await consumer.waitForRunning(timeout: timeout)
            guard attempt == generation else { throw CancellationError() }
            guard running else { throw TailnetError.needsLogin }
            watcher?.cancel()
            watcher = nil
            try await publishProxy()
        } catch {
            if attempt == generation { await teardown() }
            throw error
        }
    }

    private func startNode() throws -> LocalAPIClient {
        try FileManager.default.createDirectory(at: configuration.stateDirectory, withIntermediateDirectories: true)
        let node = try TailscaleNode(
            config: TailscaleKit.Configuration(
                hostName: configuration.hostName,
                path: configuration.stateDirectory.path(percentEncoded: false),
                authKey: nil,
                controlURL: configuration.controlURL,
                ephemeral: false
            ),
            logger: logger
        )
        let client = LocalAPIClient(localNode: node, logger: logger)
        self.node = node
        self.client = client
        return client
    }

    private func publishProxy() async throws {
        guard let node else { throw TailscaleError.badInterfaceHandle }
        let loopback = try await node.loopback()
        guard let host = loopback.ip, let port = loopback.port.flatMap({ UInt16(exactly: $0) }) else {
            throw TailscaleError.invalidProxyAddress
        }
        proxyStore.set(TailnetProxy(host: host, port: port, username: "tsnet", password: loopback.proxyCredential))
    }

    private func teardown() async {
        watcher?.cancel()
        watcher = nil
        client = nil
        try? await node?.close()
        node = nil
        proxyStore.set(nil)
    }

    private static func emptyOptions() throws -> Ipn.Options {
        try JSONDecoder().decode(Ipn.Options.self, from: Data("{}".utf8))
    }
}

private actor LoginConsumer: MessageConsumer {
    private let continuation: AsyncThrowingStream<TailnetLoginEvent, any Error>.Continuation
    private let onRunning: @Sendable () async -> Bool
    private let onIdleTimeout: @Sendable (LoginConsumer) async -> Bool
    private var lastLoginURL: URL?
    private var isFinishing = false

    init(
        continuation: AsyncThrowingStream<TailnetLoginEvent, any Error>.Continuation,
        onRunning: @escaping @Sendable () async -> Bool,
        onIdleTimeout: @escaping @Sendable (LoginConsumer) async -> Bool
    ) {
        self.continuation = continuation
        self.onRunning = onRunning
        self.onIdleTimeout = onIdleTimeout
    }

    func notify(_ notify: Ipn.Notify) {
        guard !isFinishing else { return }
        if let raw = notify.BrowseToURL, let url = URL(string: raw), url != lastLoginURL {
            lastLoginURL = url
            continuation.yield(.browseToURL(url))
        }
        if notify.State == .Running {
            isFinishing = true
            Task { await finishRunning() }
        }
    }

    func error(_ error: any Error) {
        guard !isFinishing else { return }
        guard (error as? URLError)?.code == .timedOut else {
            isFinishing = true
            continuation.finish(throwing: error)
            return
        }
        Task { await rewatch(after: error) }
    }

    private func finishRunning() async {
        if await onRunning() {
            continuation.yield(.running)
            continuation.finish()
        } else {
            continuation.finish(throwing: CancellationError())
        }
    }

    private func rewatch(after error: any Error) async {
        guard !isFinishing else { return }
        if await !onIdleTimeout(self) {
            isFinishing = true
            continuation.finish(throwing: error)
        }
    }
}

private actor ResumeConsumer: MessageConsumer {
    private let states: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (states, continuation) = AsyncStream.makeStream(of: Bool.self)
    }

    func notify(_ notify: Ipn.Notify) {
        guard notify.State == .Running else { return }
        continuation.yield(true)
        continuation.finish()
    }

    func error(_: any Error) {
        continuation.finish()
    }

    func waitForRunning(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [states] in
                for await running in states {
                    return running
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let running = await group.next() ?? false
            group.cancelAll()
            return running
        }
    }
}
