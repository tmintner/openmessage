import Combine
import Foundation
import OpenMessageKit
import os

/// Owns the OpenMessage Go backend, which on iOS runs *inside* this process.
///
/// This is the iOS counterpart to the Mac app's BackendManager, and the split
/// is forced by the platform rather than chosen: macOS spawns
/// `openmessage serve` as a child process and supervises it with lsof/ps/kill,
/// none of which exist on iOS. Foundation's `Process` is absent from the SDK
/// entirely, so the backend is linked in as a static library
/// (OpenMessageKit.xcframework) and started on a goroutine.
///
/// What that simplifies: there is no port contention, no orphaned daemon to
/// adopt or reap, and no second process racing us for the SQLite store — the
/// whole class of problems the Mac manager exists to handle cannot occur.
///
/// What it complicates: the backend's lifetime is the app's lifetime. iOS
/// suspends the process shortly after backgrounding, freezing every goroutine
/// and dropping the platform sockets. See `applicationDidBecomeActive` for how
/// that is handled on return.
@MainActor
final class EmbeddedBackend: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case needsPairing
        case error(String)
    }

    @Published var state: State = .stopped
    @Published private(set) var port: Int = 7007

    private let logger = Logger(subsystem: "com.openmessage.ios", category: "Backend")
    private var healthCheckTask: Task<Void, Never>?
    private var started = false

    /// True once the backend has been started in this process and the session it
    /// booted with has since been replaced.
    ///
    /// The Go runtime cannot be torn down and re-hosted inside a live process,
    /// so a backend that started with session A keeps using session A for the
    /// rest of the app's lifetime. Re-pairing therefore requires a relaunch, and
    /// the UI has to say so rather than silently leaving a dead Google
    /// registration in place — the exact failure the runbook warns about.
    @Published private(set) var needsRelaunch = false

    /// Per-app sandboxed Application Support directory.
    ///
    /// Unlike macOS — where the app and the CLI can point at two different
    /// stores and routinely do (see docs/agent-runbook.md) — iOS gives each app
    /// exactly one container, so this is unambiguously *the* store.
    var dataDir: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenMessage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    var sessionPath: String { dataDir + "/session.json" }

    /// Whether Google Messages pairing has already happened on this device.
    var hasSession: Bool { FileManager.default.fileExists(atPath: sessionPath) }

    // MARK: - Lifecycle

    func start() {
        guard state != .starting, state != .running else { return }

        guard hasSession else {
            state = .needsPairing
            return
        }

        state = .starting

        // Only ever boot the Go runtime once per process. Unlike a subprocess,
        // a second OMStart cannot be made to replace the first — the goroutine,
        // its SQLite handle and its transport supervisors all live for the
        // lifetime of the app. OMStart itself guards against this too; this
        // check keeps the intent visible on the Swift side.
        if !started {
            port = Self.findFreePort() ?? 7007
            let result = dataDir.withCString { dir in
                OMStart(UnsafeMutablePointer(mutating: dir), Int32(port))
            }
            logger.info("Started embedded backend on port \(self.port, privacy: .public) (rc=\(result))")
            started = true
        }

        startHealthCheck()
    }

    /// Called when the app returns to the foreground.
    ///
    /// The backend goroutines resume where iOS froze them, but any socket the
    /// system tore down while suspended is gone. The Go transport supervisors
    /// already reconnect on their own; this re-runs the health probe so the UI
    /// reflects reality instead of a stale "running" from before suspension.
    func applicationDidBecomeActive() {
        guard started else {
            start()
            return
        }
        startHealthCheck()
    }

    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            guard let self else { return }
            // Cold launch runs SQLite migrations before the listener opens, so
            // allow a generous window before calling it a failure.
            for attempt in 0..<60 {
                if Task.isCancelled { return }
                if await self.probeHealth() {
                    await MainActor.run { self.state = .running }
                    return
                }
                if let failure = await self.serveFailure() {
                    await MainActor.run { self.state = .error(failure) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(attempt < 10 ? 250 : 1000))
            }
            await MainActor.run {
                self.state = .error("Backend did not start listening on port \(self.port).")
            }
        }
    }

    private func probeHealth() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Non-nil once the serve goroutine has exited with an error.
    private func serveFailure() async -> String? {
        guard OMIsRunning() == 0 else { return nil }
        guard let raw = OMLastError() else { return nil }
        defer { free(raw) }
        let message = String(cString: raw)
        return message.isEmpty ? "Backend stopped unexpectedly." : message
    }

    /// Clears the paired session, returning the app to the pairing screen.
    ///
    /// The backend keeps running: it cannot be restarted in-process, and the
    /// pairing flow writes a fresh session.json that a relaunch picks up.
    func resetPairing() {
        try? FileManager.default.removeItem(atPath: sessionPath)
        healthCheckTask?.cancel()
        // If the backend already booted, the newly paired session cannot be
        // picked up until the process restarts.
        needsRelaunch = started
        state = .needsPairing
    }

    // MARK: - Port selection

    /// Asks the kernel for an unused loopback port.
    ///
    /// iOS loopback is device-wide rather than per-app, so a hardcoded 7007
    /// could collide with another app. Binding port 0 and reading back the
    /// assignment avoids that. There is a small race between releasing the
    /// probe socket and the Go listener claiming it, which is why 7007 remains
    /// the fallback rather than the default.
    private static func findFreePort() -> Int? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: actual.sin_port))
    }
}
