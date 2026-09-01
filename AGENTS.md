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
  **Check the destination before every test run.** Xcode reverts it to the
  attached iPhone on its own, and a run on the iPhone reports "No result" rather
  than a failure, which reads like a broken test rather than a wrong
  destination.
- One build at a time. The project is a shared resource: two `BuildProject` or
  `RunAllTests` calls at once collide, so parallel workers must edit only and
  leave building to whoever coordinates them.
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
- Avoid force unwrapping outside tests.
- A button that dismisses, abandons or accepts carries the role and no title of
  its own: `Button(role: .close)`, `Button(role: .cancel)`,
  `Button(role: .confirm)`. The system supplies the label, the glyph and the
  placement, so a role button goes straight into `.toolbar { }` rather than into
  a `ToolbarItem(placement: .cancellationAction)`. Keep a title only where it
  says more than the role does — "Add" on the confirm button of a composer. A
  toolbar cannot mix bare views with `ToolbarItem`/`ToolbarItemGroup`; make the
  whole closure views.

## Where each explanation belongs

Four places, four jobs. They repeat each other otherwise, and the copies go
stale in different directions.

| Place | Says |
| --- | --- |
| Code | **How.** The implementation is the account of how the app works. |
| Test code | **What.** A test's name and assertions state what is guaranteed. |
| Commit message | **Why.** Why the change was made, and what went wrong without it. |
| Comment | **Why not.** The alternative that was *not* taken, and what it costs. |

**Most code needs no comment at all.** A comment that says what the code does
duplicates the code; one that says why the change was made duplicates the log.
Before keeping one, ask what a reader would do wrong without it: if the answer is
"nothing", delete it; if it is "reach for the obvious thing", write that obvious
thing and its cost. What survives that test here is almost entirely what the
watch does with what it is sent — see below — and it carries the firmware
citation that proves it. Comments are about 4% of the package; treat a larger
share as a smell.

Test comments carry the *provenance* of a golden vector (the firmware constant,
the bit order, the reference file) and nothing else. Why the vector matters is
the commit message's job.

## Localization

All user-facing text goes through `PebbleKit/Sources/UI/Resources/Localizable.xcstrings`
— note the `Resources/` — and the app target's own catalog. Japanese stays at
zero untranslated strings.

- A runtime lookup **must** pass `bundle: .module`. `String(localized:)` without
  it resolves against the main bundle, finds nothing, and silently returns the
  English key. This shipped once: the watch was sent six English canned replies
  by a build whose Japanese catalog was complete.
- Before deleting a key, grep `Sources/UI` for it. Two keys have been removed
  while still in use.
- A build extracts new keys into the catalog; add the `ja` translation after
  building, and clear any `extractionState: stale` entry whose string is really
  gone.

## Lifecycle and state

The bugs worth preventing here have all been the same few shapes.

- **Every stored continuation needs a guard and two resume paths.** Guard
  against a second caller before storing one (`guard x == nil else { throw }`),
  and make sure both teardown paths — a connection that failed and a link that
  dropped — resume it. A continuation resumed by nobody hangs its caller for the
  life of the process; one resumed twice traps.
- **Cancel a stored `Task` before assigning over it.** A deadline that outlives
  the operation it guarded tears down the healthy link that replaced it.
- **Clear per-link state on both teardown paths.** A session id, a transfer
  cookie or a data-logging table that survives a disconnect is read against the
  next connection, where it means something else.
- **Isolate the failure of one frame from its batch.** The watch coalesces
  frames for unrelated endpoints into one delivery, so giving up on the first
  unusable one loses the reply a caller is waiting for and the acknowledgement
  with it.
- **Remove queued work by identity, never by position.** Sending suspends, so
  the entry at the front afterwards need not be the one just sent. The same goes
  for a view's `onDelete`: an `IndexSet` from a filtered, sorted or grouped list
  says nothing about the model array — hand the model the items themselves.
- **Guard a flush against itself.** Both the app coming forward and a watch
  finishing its synchronization ask for one; two at once dropped an unsent
  message and buzzed the watch twice for every queued notification.
- **Nothing the watch sends may raise a permission prompt.** Authorization is
  asked for only in response to something the reader started; otherwise read the
  status and do what is possible without it.
- **Say only what happened.** One `catch` over a save and a network write
  reports the wrong failure; a message that promises a rollback has to be backed
  by a rollback. State set before the awaited call that could fail is a lie the
  reader acts on.

## Dependencies

Reach for what is already in `PebbleKit/Package.swift` before adding anything:
swift-algorithms, swift-async-algorithms, swift-collections (`DequeModule`),
swift-async-operations (`asyncMap` and friends, for concurrent work that has to
stay in order), swift-http-types (typed `HTTPRequest` for every network call),
swift-retry (`DMRetry`), Defaults (typed keys in `PebbleDefaults.swift`), Valet
(keychain, in `PebbleTokenStore.swift`), MemberwiseInit, ZIPFoundation.

Work sent to a watch is retried with `retry(with: .watchWork)`
(`WatchWorkRetry.swift`), not with a hand-written loop. Add a reason to
`PebbleConnectionError.isWorthAnotherAttempt` rather than a special case at a
call site.

Notifications between the app's own parts are typed `NotificationCenter`
messages (`PebbleWindowMessages.swift`), not `Notification.Name` plus an
untyped `object`. Foundation's message API needs a class as the subject, and the
model a window shows is that class.

## Protocol reference

The wire protocol is not documented publicly. Two checkouts answer questions
about it, and they answer different ones.

[coredevices/PebbleOS](https://github.com/coredevices/PebbleOS), locally at
`/Users/zunda/Documents/GitHub/PebbleOS-Swift`, is the watch firmware — the
other end of every conversation, and the last word on what the watch actually
does. Worth knowing: `src/fw/services/comm_session/` (framing, the endpoint
router, and `meta_endpoint.c`, which is the `0xDC`/`0xDD` refusal on endpoint 0),
`src/fw/services/put_bytes/put_bytes.c` (the transfer state machine, its tokens
and its responses), `src/fw/services/firmware_update/`,
`src/fw/services/app_fetch_endpoint/`. `CONFIG_RECOVERY_FW` guards mark what
recovery firmware refuses to do.

[coredevices/mobileapp](https://github.com/coredevices/mobileapp), locally at
`/Users/zunda/Documents/GitHub/mobileapp`, is the official companion app; its
Kotlin `libpebble3` module is what the codecs here were written against. Read it
for **logic only** — byte layouts, sequencing, which endpoint answers what. Its
UI and UX are not a model for this app's; `composeApp/` and `iosApp/` have
nothing to teach us.

Both are long-lived codebases and both contain bugs. Neither is authority on its
own: check a claim in both, and where they disagree, the firmware wins. Where
neither explains what a watch is doing, the device log does — say what was
observed rather than what ought to happen. Match byte layouts exactly; the watch
silently drops anything it cannot parse.

**A struct definition is not the wire format.** PebbleOS runs on ARM, so "the
firmware sends the struct verbatim" reads as little-endian — but the field may
already have been swapped when it was built. `pbl_log_binary_format`
(`src/fw/applib/logging.c`) puts a log record's timestamp and line number through
`htonl`/`htons`, and `htonl`/`htons` in `src/fw/util/net.h` are unconditional
swaps. Reasoning from `LogBinaryMessage` alone produced both a wrong bug report
against the official app and a real bug here. Follow every field to the line that
*assigns* it, not just to its declaration.

Firmware packages (`.pbz`) match on **board revision** (`hwrev`), not on watch
model. Watch apps (`.pbw`) match on platform.

### What the watch does with what it is sent

These are the facts that have cost the most to learn. Each is worth a comment at
the code that depends on it.

- **A string cut mid-character is drawn as nothing at all.** `utf8_get_bounds`
  fails, the text layout gives up, and the field is empty — a Japanese title one
  character too long vanishes rather than losing its tail. Cut on a character
  boundary, with `String.utf8BytesEndingOnACharacter(maximumByteCount:)`.
- **Attribute lengths are the firmware's, and it truncates without mercy.**
  `MAX_ATTRIBUTE_LENGTHS` (`src/fw/services/timeline/attribute.c`): title 64,
  subtitle 64, body 512. Sending more lets the watch make the mid-character cut
  above.
- **Capability bits gate whole features.** The firmware reads the phone's claim
  once, while connecting: without the weather bit it refuses a weather write,
  without the reminders bit it hides the Reminders app, without the
  extended-music bit it reads only the first three fields of a now-playing frame,
  without the smooth-progress bit it ignores the byte counts an update sends.
  Claim a bit only where the code behind it exists — and remember to claim it.
- **Some endpoints are Android-only.** `music_endpoint_handle_mobile_app_info_event`
  returns unless the phone reported `RemoteOSAndroid`, so Pebble Protocol music
  control never activates for a phone that truthfully reports iOS or macOS
  (issue #31). Reporting the OS honestly is deliberate.
- **A bonded Pebble stops advertising.** It cannot be scanned for; it is looked
  up by stored identifier, or it turns up by subscribing to the phone's own GATT
  service.
- **An unbonded watch publishes its protocol service only once encrypted**, so
  the first discovery sees the pairing service alone and the phone has to host
  the transport itself. That choice is per link and has to be undone when the
  watch's own service appears.
- **Recovery firmware answers version and ping only**, and refuses the rest on
  endpoint 0. It also drops the link a few seconds after connecting.
- **Two fields can mean the same setting.** The heart-rate `enabled` flag gates
  what an app may ask for; the sampling loop consults the interval alone, so
  turning a reading off has to be written into both.
- **An install's response cookie is zero**, because the commit that precedes it
  has already cleared the transfer state the firmware answers from (issue #10).

## Conventions

- No handoff notes, status reports or plan documents in the repository. What is
  worth keeping goes in code, in a commit message, or in a GitHub issue.
- If something cannot be implemented because Apple ships no public API for it,
  open a GitHub issue in Japanese naming the API and the code location, rather
  than leaving a workaround unexplained.
- A bug found anywhere — in this app, in the firmware, in the official app —
  gets a GitHub issue on `zunda-pixel/pebble-app`, in Japanese: what was
  observed, where it comes from (file and function, cited in the reference
  checkout), and the workaround in use here if there is one, with the code that
  implements it. A bug that is only in a commit message is a bug nobody can
  find. See issue #10 for the shape of one.
- An issue filed against a reference implementation that turns out to be this
  app's own bug gets corrected in public: a comment saying what the mistake in
  reading was, and the issue closed. See issue #26, which claimed the official
  app read a log record with the wrong byte order when the firmware had swapped
  it on the way out.
- Commit messages describe the change and the reason for it in prose. Keep
  changes scoped to what was asked.
