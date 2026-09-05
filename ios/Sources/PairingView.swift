import SwiftUI

/// Pairing screen for iPadOS.
///
/// Only the Google account path is offered. QR pairing is dead upstream (see
/// docs/agent-runbook.md), and the Mac app's alternative — pasting a cURL
/// command copied from desktop DevTools — has no equivalent on iPad. Signing in
/// through the embedded web view and harvesting cookies is the one flow that
/// works with only the tablet in hand.
struct PairingView: View {
    @ObservedObject var backend: EmbeddedBackend
    @StateObject private var coordinator = PairingCoordinator()

    var body: some View {
        Group {
            switch coordinator.phase {
            case .idle:
                intro
            case .signingIn:
                signIn
            case .pairing:
                progress(title: "Contacting Google…",
                         detail: "Setting up the link to Google Messages.")
            case .awaitingEmoji(let emoji):
                emojiConfirmation(emoji)
            case .succeeded:
                success
            case .failed(let message):
                failure(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Steps

    private var intro: some View {
        VStack(spacing: 24) {
            Image(systemName: "message.badge.filled.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Connect Google Messages")
                .font(.largeTitle.weight(.semibold))

            Text("Sign in to the Google account your phone uses for Messages. "
                 + "You'll confirm an emoji on your phone to finish linking.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button("Sign in with Google") { coordinator.beginSignIn() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Text("Your Google password is never seen by OpenMessage — sign-in "
                 + "happens in an isolated web view that stores nothing.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
    }

    private var signIn: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { coordinator.cancel() }
                Spacer()
                Text("Sign in to Google").font(.headline)
                Spacer()
                Button("Cancel") { }.hidden() // balances the title
            }
            .padding()
            .background(.bar)

            GoogleSignInView(
                onCookiesReady: { header in
                    coordinator.pair(cookieHeader: header, dataDir: backend.dataDir)
                },
                onLoadError: { message in
                    coordinator.cancel()
                }
            )
        }
    }

    private func emojiConfirmation(_ emoji: String) -> some View {
        VStack(spacing: 24) {
            Text("Tap this emoji on your phone")
                .font(.title2.weight(.semibold))

            Text(emoji)
                .font(.system(size: 96))
                .padding(32)
                .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 24))

            Text("Open Google Messages on your phone and select this emoji to "
                 + "confirm the link.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            ProgressView()
        }
        .padding(40)
    }

    private func progress(title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.4)
            Text(title).font(.title3)
            Text(detail).foregroundStyle(.secondary)
        }
        .padding(40)
    }

    private var success: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Paired").font(.title.weight(.semibold))

            if backend.needsRelaunch {
                // The backend is already running against the previous session
                // and cannot reload in place, so promising it will just work
                // would be a lie. Ask for the relaunch instead of offering a
                // button that quietly does nothing useful.
                Text("Quit OpenMessage and open it again to finish connecting.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                Text("OpenMessage is linked to Google Messages.")
                    .foregroundStyle(.secondary)
                Button("Start OpenMessage") { backend.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(40)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Pairing failed").font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Try again") { coordinator.beginSignIn() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
    }
}
