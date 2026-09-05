import Combine
import Foundation
import OpenMessageKit

/// Drives Google account pairing against the in-process backend.
///
/// The Mac app spawns `openmessage pair --google-stdin` and parses the child's
/// stdout. Here OMPairGoogle runs the same cmd.RunPair in-process and captures
/// that stdout, so the lines parsed below are byte-identical to the ones the
/// Mac app sees — notably "EMOJI: X", the character the user must tap in Google
/// Messages on their phone to confirm the pairing.
@MainActor
final class PairingCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case signingIn          // user is signing in to Google in the web view
        case pairing            // cookies handed off, waiting for the emoji
        case awaitingEmoji(String)
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: [String] = []

    private var pollTask: Task<Void, Never>?

    func beginSignIn() {
        phase = .signingIn
        log = []
    }

    /// Hands harvested Google cookies to the backend and starts pairing.
    func pair(cookieHeader: String, dataDir: String) {
        phase = .pairing

        // RunPair takes cookies via --google-file. Write them inside the app
        // container (not /tmp) so the file inherits the same data protection as
        // the rest of the store, and delete-on-read is handled Go-side.
        let path = (dataDir as NSString).appendingPathComponent("google-cookies.pairing")
        do {
            try cookieHeader.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path
            )
        } catch {
            phase = .failed("Could not stage Google credentials: \(error.localizedDescription)")
            return
        }

        let rc = path.withCString { OMPairGoogle(UnsafeMutablePointer(mutating: $0)) }
        guard rc == 0 else {
            phase = .failed("Pairing is already in progress.")
            return
        }
        startPolling()
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let status = Self.readStatus() else { return }
                await MainActor.run { self?.apply(status) }
                if status.done { return }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func apply(_ status: PairStatus) {
        log = status.output

        // "EMOJI: 🍕" — the confirmation character to tap on the phone.
        if let line = status.output.last(where: { $0.hasPrefix("EMOJI:") }) {
            let emoji = line.dropFirst("EMOJI:".count).trimmingCharacters(in: .whitespaces)
            if !emoji.isEmpty, phase != .succeeded {
                phase = .awaitingEmoji(emoji)
            }
        }

        guard status.done else { return }
        if status.error.isEmpty {
            phase = .succeeded
        } else {
            phase = .failed(status.error)
        }
    }

    private struct PairStatus: Decodable {
        let running: Bool
        let done: Bool
        let error: String
        let output: [String]
    }

    private static func readStatus() -> PairStatus? {
        guard let raw = OMPairStatus() else { return nil }
        defer { free(raw) }
        let json = String(cString: raw)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PairStatus.self, from: data)
    }
}
