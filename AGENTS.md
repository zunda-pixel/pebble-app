# AGENTS.md

A native companion app for Pebble smartwatches, written in Swift 6. The package
targets iOS 27 and macOS 27; the app target also builds for visionOS.

## Layout

| Path | What lives there |
| --- | --- |
| `Pebble.xcodeproj` | The app project. One shared scheme, `Pebble`. |
| `Pebble/` | App target: `MainApp.swift`, `Info.plist`, entitlements, app-level strings. |
| `PebbleKit/` | Local Swift package with everything else. Its only product, `PebbleKit`, exports the `UI` target. |
| `PebbleKit/Sources/API` | Protocol and transport layer: BLE client, PPoG, endpoint codecs, package importers, persistence. No SwiftUI. |
| `PebbleKit/Sources/UI` | `AppModel` (split across `AppModel+*.swift`), the views, and the system bridges (HealthKit, EventKit, MediaPlayer, CallKit, WebKit). |
| `PebbleKit/Tests/APITests` | Swift Testing suites for the protocol layer, grouped by what they exercise. |
| `PebbleKit/Tests/UITests` | Swift Testing suites for `AppModel` against `MockPebbleClient`. |
| `AllTests.xctestplan` | Covers both test targets. |

One endpoint codec per file, named after the endpoint. One view per file. When a
file grows past roughly 500 lines, split it along a seam that already exists
rather than by line count.

## Building and testing

**Everything goes through the Xcode project.** Never run `swift build` or
`swift test`: the package's settings, destinations and test plan are not what
ships, so a green SwiftPM run says little about the app.

- Build with the `BuildProject` MCP command from `xcode-tools`.
- Test with `RunAllTests` / `RunSomeTests`. The `Pebble` scheme's test plan
  already covers both targets.
- **Run tests on the `My Mac` destination.** On a device the package test
  targets are skipped ("Tool-hosted testing is unavailable on device
  destinations"), and on an iOS simulator the whole `APITests` bundle currently
  crashes in `Runner._applyScopingTraits` even though every case passes
  individually and on macOS. Build for the iPhone; test on the Mac.
- `XcodeRefreshCodeIssuesInFile` is the fast way to check one file before paying
  for a full build.

Anything that touches Bluetooth has to be verified on a real iPhone against a
real watch. The simulator has no CoreBluetooth peripheral or GATT server.

Do not edit `Pebble.xcodeproj/project.pbxproj` by hand. Change build settings
with `UpdateTargetBuildSetting`, and add or move files with the `xcode-tools`
file commands.

## Swift settings

The package builds in Swift 6 language mode with `defaultIsolation(nil)`,
`strictMemorySafety()`, and these upcoming features on every target:
`ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`,
`InferIsolatedConformances`, `ImmutableWeakCaptures`,
`NonisolatedNonsendingByDefault`.

Two consequences worth knowing before you write an import or a lock:

- `MemberImportVisibility` means an umbrella import is not enough — import the
  module that actually declares what you use (`import DequeModule`, not
  `import Collections`).
- `strictMemorySafety()` rejects the unsafe pointer tricks usually reached for
  when packing integers into bytes. Use `IntegerBytes.swift`
  (`bigEndianBytes`, `littleEndianBytes`, `hexadecimalString`) instead.

For shared mutable state, use an `actor`, or `Mutex` from `Synchronization` when
the call site is synchronous (a delegate callback, a `URLProtocol` override).
Not `NSLock`, and not `nonisolated(unsafe)`.

## Style

- PascalCase types, camelCase members. `let` unless mutation is needed.
- `@State private var` for view state; `@Observable` and `@MainActor` for models.
- 4-space indentation in the app and package sources.
- Prefer `async`/`await`. Do not introduce Combine.
- Comments explain *why*, especially where the wire format or a framework
  forces an odd shape. Do not narrate what the next line obviously does.
- Avoid force unwrapping outside tests.
- All user-facing text goes through the string catalogs, which are localized to
  English and Japanese. Localize new strings in both.

## Dependencies

Reach for what is already in `PebbleKit/Package.swift` before adding anything:
swift-algorithms, swift-async-algorithms, swift-collections (`DequeModule`),
swift-async-operations (`asyncMap` and friends, for concurrent work that has to
stay in order), swift-http-types (typed `HTTPRequest` for every network call),
Defaults (typed keys in `PebbleDefaults.swift`), Valet (keychain, in
`PebbleTokenStore.swift`), MemberwiseInit, ZIPFoundation.

Notifications between the app's own parts are typed `NotificationCenter`
messages (`PebbleWindowMessages.swift`), not `Notification.Name` plus an
untyped `object`. Foundation's message API needs a class as the subject, and the
model a window shows is that class.

## Protocol reference

The wire protocol is not documented publicly. When behaviour is in question,
read [coredevices/mobileapp](https://github.com/coredevices/mobileapp) — the
Kotlin `libpebble3` module is the reference implementation, and it is what the
codecs here were written against. Match its byte layouts exactly; the watch
silently drops anything it cannot parse.

Firmware packages (`.pbz`) match on **board revision** (`hwrev`), not on watch
model. Watch apps (`.pbw`) match on platform.

## Conventions

- No handoff notes, status reports or plan documents in the repository. What is
  worth keeping goes in code, in a commit message, or in a GitHub issue.
- If something cannot be implemented because Apple ships no public API for it,
  open a GitHub issue in Japanese naming the API and the code location, rather
  than leaving a workaround unexplained.
- Commit messages describe the change and the reason for it in prose. Keep
  changes scoped to what was asked.
