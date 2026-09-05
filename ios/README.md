# OpenMessage for iPadOS

A standalone iPad app: the Go backend runs **inside** the app process, so the
iPad pairs, stores and serves its own messages with no Mac involved.

## How it differs from the Mac app

The Mac app spawns `openmessage serve` as a child process and supervises it
(`macos/OpenMessage/Sources/BackendManager.swift`). iOS has no fork/exec —
Foundation's `Process` isn't even in the SDK — so instead the whole backend is
compiled to a static library and linked into the app:

```
mobile/            Go → C entrypoints (OMStart, OMPairGoogle, …)
ios/build-framework.sh   → OpenMessageKit.xcframework
ios/Sources/       SwiftUI app; EmbeddedBackend.swift replaces BackendManager
```

This works because every dependency is pure Go — `modernc.org/sqlite` in
particular, so there is no C SQLite to cross-compile.

Some Mac problems simply vanish: no port contention, no orphaned daemon to adopt
or reap, no second process racing for the store. The trade is that the backend's
lifetime *is* the app's lifetime.

## Build and run

```bash
./ios/build-framework.sh                       # Go → xcframework (~2 min)
xcodegen generate --spec ios/project.yml       # → ios/OpenMessage.xcodeproj
open ios/OpenMessage.xcodeproj                 # select your iPad, ⌘R
```

`ios/project.yml` is the source of truth. The `.xcodeproj` and `ios/Info.plist`
are **generated and git-ignored** — add Info.plist keys under `info.properties`
in the spec, because editing the plist directly is silently overwritten on the
next `xcodegen generate`.

Rebuild the framework whenever Go code changes; Xcode does not know about the Go
sources and will happily link a stale archive. (A missing symbol at link time
usually means exactly this.)

For a signed install on your own iPad: open the project, select the OpenMessage
target → Signing & Capabilities → your personal team, then run to the device.

Verify a UI change without an iPad:

```bash
xcrun simctl boot "iPad Pro 11-inch (M5)"
xcodebuild -project ios/OpenMessage.xcodeproj -scheme OpenMessage \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath ios/build/dd build
xcrun simctl install booted ios/build/dd/Build/Products/Debug-iphonesimulator/OpenMessage.app
SIMCTL_CHILD_OPENMESSAGES_DEMO=1 xcrun simctl launch booted com.openmessage.ios
```

`OPENMESSAGES_DEMO=1` serves seeded fake data with live transports disabled —
the right way to exercise the UI, since pairing the simulator with real Google
credentials would fight the Mac daemon for the same session.

## Pairing

Google account pairing only. QR pairing is dead upstream, and the Mac's other
route — pasting a cURL command from desktop DevTools — has no iPad equivalent.
The app signs in through an isolated web view, harvests the Google cookies libgm
needs (`SAPISID`), and hands them to `OMPairGoogle`, which runs the same
`cmd.RunPair` the CLI does and surfaces the confirmation emoji to tap on
your phone.

**Re-pairing requires relaunching the app.** The Go runtime cannot be torn down
and re-hosted inside a live process, so a backend that booted with one session
keeps using it. The pairing screen says so rather than pretending otherwise.

## Known limits on iPadOS

These are platform constraints, not missing work:

- **No background sync.** iOS suspends the process within ~30s of backgrounding,
  freezing the goroutines and dropping the Google/WhatsApp/Signal sockets.
  Messages arrive while the app is in the foreground; on return, the supervisors
  reconnect and catch up. There is no entitlement that makes an iPad hold a
  persistent messaging socket the way the Mac daemon does.
- **No iMessage or Signal Desktop import.** Both read desktop databases
  (`~/Library/Messages/chat.db`, the Signal Desktop support dir) that do not
  exist on iPadOS. The Go side already gates these off `runtime.GOOS`, so they
  disable themselves rather than failing at runtime.
- **No native notifications yet.** The bridge deliberately does not declare
  `OpenMessageNativeNotifications`: with the app suspended in the background
  there is nothing listening to raise a banner, and advertising the capability
  would give the UI a dead toggle.
- **Not App Store distributable in practice.** Unofficial Google Messages,
  WhatsApp and Signal clients would very likely fail App Review. Personal
  dev-signing to your own device is the realistic path.
