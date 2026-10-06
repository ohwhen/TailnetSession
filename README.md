# TailnetSession

Join a tailnet from inside an iOS app and send its `URLSession`, WebSocket and `WKWebView` traffic over it. No VPN profile, no Network Extension, no extra entitlement.

TailnetSession ships two things:

- **A slim `TailscaleKit.xcframework`**, built in CI from a pinned [libtailscale](https://github.com/tailscale/libtailscale) commit with the Tailscale features an app-embedded client never touches compiled out.
- **A small Swift layer** on top of it that signs in through the browser, brings the node back silently after a relaunch, and publishes the node's SOCKS5 proxy so the rest of the app can route through it.

## Install

```swift
.package(url: "https://github.com/ohwhen/TailnetSession.git", from: "0.1.0")
```

Then add the `TailnetSession` product to your target. It re-exports `TailscaleKit`.

## Usage

```swift
import TailnetSession

let tailnet = Tailnet(configuration: .init(hostName: "my-app"))

// first run: sign in through the browser
for try await event in tailnet.login() {
    if case let .browseToURL(url) = event {
        await UIApplication.shared.open(url)
    }
}

// every later launch: come back without asking
do {
    try await tailnet.resume()
} catch TailnetError.needsLogin {
    // the stored session is gone, run login() again
}

// route a session through the node
guard let proxy = tailnet.proxyStore.current else { return }
let configuration = URLSessionConfiguration.default
configuration.route(through: proxy)
let session = URLSession(configuration: configuration)
let (data, _) = try await session.data(from: URL(string: "https://my-server.my-tailnet.ts.net")!)
```

WebSockets come from the same session: `session.webSocketTask(with:)` honors the proxy. A web view needs its own store:

```swift
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .tailnet(proxy)
```

| API | What it does |
|---|---|
| `Tailnet.login()` | Interactive sign-in. Yields `.browseToURL` for each sign-in link, then `.running` once the proxy is published, then ends. Cancelling the iterating task stops the node. |
| `Tailnet.resume(timeout:)` | Restarts a signed-in node from `stateDirectory`. Concurrent calls share one attempt. Throws `TailnetError.needsLogin` when the session is gone. |
| `Tailnet.disconnect()` | Stops the node and clears the proxy. The session stays on disk for `resume()`. |
| `TailnetProxyStore` | Where the running node's proxy lives. `current`, `waitUntilReady(timeout:)`, and a `snapshot` whose `epoch` changes on every publish, so a client can rebuild its session after a reconnect even when the proxy values repeat. |
| `URLSessionConfiguration.route(through:)` | Sends every task of the session through the tailnet. |
| `WKWebsiteDataStore.tailnet(_:)` | A non-persistent, proxied store for web content on the tailnet. |

## The binary

`Scripts/build-xcframework.sh` builds it from the commit in `tailscale.ref`. Run it yourself with Go and Xcode installed; `MIN_IOS=18.0` changes the deployment target.

Every day a workflow checks libtailscale's `main`. When it has moved, the workflow builds TailscaleKit from the new commit, runs the package tests on a simulator, and opens a PR that bumps `tailscale.ref`. Merging that PR publishes the binary as a `tailscalekit-<commit>` release, points `Package.swift` at it, installs the package from the release URL to test it again, and tags the next patch version.

- Go is linked with `-ldflags '-w -s' -trimpath`, and 27 `ts_omit_*` tags drop SSH, Taildrop, Drive, Kubernetes, app connectors, exit-node and route advertising, the relay server, Tailnet Lock, OS routing and DNS managers, and the rest of the daemon and desktop surface.
- Netstack, DNS, WireGuard, DERP and the control client stay, and so do `serve` and `acme`, because `tsnet` calls into both.
- The simulator slice is arm64 only. Both slices share one deployment target.
- Binaries are stripped. The module ships its `.swiftinterface` only: no compiled `.swiftmodule`, `.abi.json` or source info, so no build-machine paths.
- The current release is a 14.6 MB zip, and the device binary is 19.4 MB.
- Each slice carries an empty `PrivacyInfo.xcprivacy`, the same declaration proposed upstream in [libtailscale#57](https://github.com/tailscale/libtailscale/pull/57), and a `LICENSES.txt`.

## Things that will bite you

- **IPv6-only networks.** Many cellular networks are IPv6-only behind NAT64. A server whose public DNS name has only an A record pointing at a `100.x` tailnet address gets a DNS64-synthesized IPv6 address from the device before the request ever reaches the proxy, and the node cannot route it. Requests time out on cellular and work on dual-stack Wi-Fi. Names the device cannot resolve on its own, such as MagicDNS names, go to the proxy unresolved and work everywhere.
- **MagicDNS needs CorpDNS.** `Tailnet` turns it on, so the node can resolve `*.ts.net` names the device's resolver does not know.
- **Do not call `up()` to resume.** A node that signed in through the browser fails `TailscaleNode.up()`. `resume()` restarts it through LocalAPI `start` and `WantRunning` instead.
- **The IPN bus drops a quiet watch after 60 seconds** ([libtailscale#62](https://github.com/tailscale/libtailscale/pull/62)). Without handling, a user who spends longer than that in the browser sees the sign-in fail. `login()` re-arms the watch.
- **TLS checks the name you dial.** Dial the hostname the server's certificate covers. Accepting a mismatched certificate through `URLSessionDelegate` does not work for this traffic.
- **Starscream ignores proxy settings.** Its `NativeEngine` builds its own `URLSession`. Use `URLSessionWebSocketTask` from a routed session, or give your engine a routed configuration.
- **Keep proxied web content out of the default store.** A proxy set on `WKWebsiteDataStore.default()` reroutes every web view in the app.
- **Nodes are not ephemeral.** Each install registers a machine in your tailnet and keeps its key in `stateDirectory`. Remove retired devices from the admin console.

## Requirements

iOS 17 or later, Xcode 16 or later.

## License

TailnetSession is MIT licensed. `TailscaleKit.xcframework` is libtailscale (BSD-3-Clause, Copyright Tailscale Inc & AUTHORS) and the Go modules it links; `LICENSES.txt`, attached to every release and placed inside each framework slice, reproduces all of their licenses.

This project is not affiliated with or endorsed by Tailscale Inc.
