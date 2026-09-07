# AGENTS.md

A native companion app for Pebble smartwatches, written in Swift 6. The package
targets iOS 27 and macOS 27; the app target also builds for visionOS.

## Layout

| Path | What lives there |
| --- | --- |
| `Pebble.xcodeproj` | The app project. One shared scheme, `Pebble`. |
| `Pebble/` | App target: `MainApp.swift`, `Info.plist`, entitlements, app-level strings. |
| `PebbleKit/` | Local Swift package with everything else. Its only product, `PebbleKit`, exports the `PebbleApp` target. |
| `PebbleKit/Sources/PebbleProtocol` | What the watch says and what the phone says back. **Foundation only** — no CoreBluetooth, no SwiftUI, so it holds anywhere and a test of it needs no radio. Five folders, below. |
| &nbsp;&nbsp;`Wire/` | The link itself: frames, PPoG, the advertisement, the pairing state, the `PebbleClient` protocol every transport implements, and the byte helpers. |
| &nbsp;&nbsp;`Codecs/` | One endpoint codec per file, plus the values they carry over the wire. |
| &nbsp;&nbsp;`Storage/` | The stores, one per file, all of them over `PersistentJSON`. |
| &nbsp;&nbsp;`Catalogs/` | What is fetched from the network: apps, firmware, language packs, and the download and retry policy they share. |
| &nbsp;&nbsp;`Packages/` | The package formats: `.pbw` and `.pbz`. |
| `PebbleKit/Sources/PebbleAudio` | What the watch's microphone sent, turned back into samples: the only place that imports `speex`. |
| `PebbleKit/Sources/PebbleTransport` | How those bytes reach a watch: the CoreBluetooth client in both roles, the phone-hosted GATT server, the emulator socket, and the mock a test or a preview stands in. |
| `PebbleKit/Sources/PebbleApp` | The app: `AppModel` (split across `AppModel+*.swift`), the screens, and the phone's own frameworks (HealthKit, EventKit, MediaPlayer, CallKit, WebKit). |
| `PebbleKit/Tests/PebbleProtocolTests` | Swift Testing suites for the protocol and transport layers, grouped by what they exercise. |
| `PebbleKit/Tests/PebbleAppTests` | Swift Testing suites for `AppModel` and the content views, against `MockPebbleClient`. |
| `AllTests.xctestplan` | Covers both test targets. |

The three targets are split by what they are allowed to depend on, and the
compiler is what keeps them honest: a codec cannot reach for CoreBluetooth, and
neither a codec nor a transport can reach for SwiftUI. A seam between two of them
uses `package` access rather than `public` — the package is one unit, and the
library's public surface is only what the app target needs.

One endpoint codec per file, named after the endpoint, and **nothing else in it**
— a store that lived beside a codec was reached for by the app on the strength of
having imported the module, and neither file could then be read on its own. One
store per file too, under `Storage/`, named `…Store`. `PebbleApplicationLibrary`
is the exception: the reader's collection of watch apps really is a library, and
that is what the screens call it.

One view per file. When a file grows past roughly 500 lines, split it along a
seam that already exists rather than by line count.

## Building and testing

**Everything goes through the Xcode project.** Never run `swift build` or
`swift test`: the package's settings, destinations and test plan are not what
ships, so a green SwiftPM run says little about the app.

- Build with the `BuildProject` MCP command from `xcode-tools`.
- Test with `RunAllTests` / `RunSomeTests`. The `Pebble` scheme's test plan
  already covers both targets.
- **Run tests on the `My Mac` destination.** On a device the package test
  targets are skipped ("Tool-hosted testing is unavailable on device
  destinations"), and on an iOS simulator the whole `PebbleProtocolTests` bundle
  currently crashes in `Runner._applyScopingTraits` even though every case passes
  individually and on macOS. Build for the iPhone; test on the Mac.
  **Check the destination before every test run.** Xcode reverts it to the
  attached iPhone on its own, and a run on the iPhone reports "No result" rather
  than a failure, which reads like a broken test rather than a wrong
  destination.
- **A result with no `xcresultBundlePath` is a result that did not happen.**
  When the test build fails, `RunAllTests` and `RunSomeTests` answer with the
  previous run's numbers, so the reply carries a plausible total and a few cases
  marked "No result" while nothing ran at all. That field is the only reliable
  tell: `state: "No result"` reads like a genuine failure, and the total is
  wrong only against a previous count nobody wrote down. Check it on every run,
  and never report counts from a reply that lacks it. A round trip of the
  destination — iPhone, then back to My Mac — is the cheap way to get a real
  run, and is worth doing before the first run after adding a test.
- One build at a time. The project is a shared resource: two `BuildProject` or
  `RunAllTests` calls at once collide, so parallel workers must edit only and
  leave building to whoever coordinates them.
- **Adding or removing a stored property on a `public` type in the package
  needs the build products thrown away.** The incremental build leaves a test
  bundle linked against the old memory layout, and the run then dies in
  `libmalloc` or `os_unfair_lock` — thirty-odd tests "failing" with heap
  corruption in code that has nothing to do with the change, each one passing
  when run on its own. `rm -rf DerivedData/Pebble/Build/Products
  DerivedData/Pebble/Build/Intermediates.noindex` and build again. A
  memory-safety failure that a clean build makes go away was never in the code.
- `XcodeRefreshCodeIssuesInFile` is the fast way to check one file before paying
  for a full build.
- **A test that builds an `AppModel` passes it a `storageDirectory` of its
  own.** Swift Testing runs tests concurrently, so two models sharing a
  directory share their queues: one test's pending notification was flushed to
  another test's watch, and a full run rewrote the reader's real notification
  history (#59). A full run that fails two or three of the wall-clock bridge
  tests and passes each of them alone is this, not the code under test.

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
- A type that has to hold a C library's state marks each such expression
  `unsafe` and carries `@safe` itself, so the unsafety stops at its own
  boundary instead of spreading to every caller (`SpeexAudioDecoder`). Keep that
  type small and let nothing else import the C module.
- **A class initializer that throws after its last property is assigned still
  runs `deinit`.** Freeing the C state on the way out of such a `guard` frees it
  twice, and the second one aborts the process — which arrives as a crash in
  whichever test happened to be running beside it. Assign, then throw, and leave
  the freeing to `deinit`.

For shared mutable state, use an `actor`, or `Mutex` from `Synchronization` when
the call site is synchronous (a delegate callback, a `URLProtocol` override).
Not `NSLock`, and not `nonisolated(unsafe)`.

## Naming

**Drop `Pebble` where the module or the enclosing type already says it and the
bare name is unambiguous.** Every type in this package is about a Pebble, so
the prefix carried no information on sixty-odd of them: `PebbleWeatherReport`
in a file called `WeatherCodec.swift` in a target called `PebbleProtocol`.

Keep it where **"Pebble" is part of a proper noun** — `PebbleOSFirmwareCatalog`
(PebbleOS is the firmware's name), `PebbleProtocolFrame` (Pebble Protocol is
the protocol's), `PPoGSession`, `PBWPackage`, `PBZFirmwarePackage`,
`PebbleColor` (the watch's own palette), `PebbleCRC32` (the firmware's variant,
not the standard one), `PebbleCompanionRuntime` and `PebbleTokenStore` (PebbleKit
JS names them) — or where **the bare word would collide** with Foundation or
SwiftUI.

The rest still carry it, and lose it as they are next touched rather than in
one sweep. "Watch" is the word for the thing on the reader's wrist:
`ConnectedWatch`, `DiscoveredWatch`, `SavedWatch`, `WatchModel`, `WatchID`.
Never "device".

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

## Views and previews

**A view without a `#Preview` is not finished.** Every state worth looking at
gets one — populated, empty, mid-transfer, watch away — because that is the only
way most of this UI is ever seen: a real watch is needed to reach it in the app,
and the Mac and the phone lay it out differently.

Which means a view has to be previewable without a watch, and that shapes the
code:

- **Split each screen in two.** A thin `SomethingView` that reads `AppModel` and
  hands the pieces down, and a `SomethingContent` that takes plain values and
  closures — `pins: [PebbleTimelinePin]`, `remove: ([PebbleTimelinePin]) -> Void`
  — and holds the layout. The content view is what gets the previews, and what a
  test can construct.
- **Never reach for `AppModel` from inside the layout.** A screen that loads its
  own data in `.task` previews as empty whatever sample data is handed to it, and
  a test of it needs a model, a client and a directory on disk.
- **Sample values live in `PreviewSamples.swift`**, one place, so a screen and
  the rows it is made of are previewed against the same data and a changed type
  is one compile error instead of a dozen.
- Previews are not `#if DEBUG`-guarded: they compile with everything else, so
  `RunAllTests` and `BuildProject` catch a preview that has gone stale.
- `RenderPreview` renders one for real, and is worth doing: it caught an all-day
  pin whose time column read "3" because the format was `.dateTime.day()`. Note
  that it switches the run destination to the device, so set it back to `My Mac`
  before testing.

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

All user-facing text goes through `PebbleKit/Sources/PebbleApp/Resources/Localizable.xcstrings`
— note the `Resources/` — and the app target's own catalog. Japanese stays at
zero untranslated strings.

**Every lookup has to name this module's bundle.** `Text("…")`,
`Section("…")`, `Button("…")` and every other SwiftUI initializer taking a
`LocalizedStringKey` searches `Bundle.main` — the app — whatever module the view
was compiled into, and these screens are in a package whose strings ship in a
bundle of their own. A Japanese iPhone showed the whole app in English against a
finished catalogue because of it.

- `ModuleLocalization.swift` declares the same initializers inside this module
  and fills the bundle in, so `Text("Devices")` in a view needs nothing at the
  call site. **A SwiftUI API used with a literal and missing from that file
  silently falls back to the main bundle**, so a screen whose text comes out
  English is a missing shim, not a missing translation.
- A *modifier* cannot be shimmed — `navigationTitle`, `accessibilityLabel`,
  `accessibilityHint` and `confirmationDialog` differ from ours only in return
  type, which the compiler calls ambiguous. Those take `Text("…")` at the call
  site instead.
- A runtime lookup passes `bundle: .module` for the same reason.
  `String(localized:)` without it returns the English key. This shipped once:
  the watch was sent six English canned replies by a build whose Japanese
  catalogue was complete.
- Before deleting a key, grep `Sources/PebbleApp` for it. Two keys have been removed
  while still in use.
- A build extracts new keys into the catalog; add the `ja` translation after
  building, and clear any `extractionState: stale` entry whose string is really
  gone.

## Lifecycle and state

The bugs worth preventing here have all been the same few shapes.

- **A retry loop needs a way to end, and a reason to show when it does.** Count
  the failures that mean "this will not work" — a link that comes up and dies in
  the handshake — rather than trusting a backoff, whose attempt counter says
  nothing when the attempt itself keeps succeeding. Reset the count when the
  thing actually works, stop after a handful, and say which watch and why: a
  loop with no end reads on screen as "Reconnecting…" forever.
- **One outstanding request means a queue, not a refusal.** BlobDB and app
  messages each answer by token, so the client may have one in flight — the
  callers are unrelated features on unrelated timers, and the one that loses the
  race must wait its turn rather than be told the watch refused it.
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
(keychain, in `PebbleTokenStore.swift`), MemberwiseInit, ZIPFoundation,
CSpeex (libspeex, imported as `speex`, used only by `PebbleAudio`).

A C library is the last resort, for a format the watch dictates and no Apple
framework reads: today only Speex. Prefer a package to a copy in this
repository. When one exists, read what it actually ships before depending on
it — a packaging tagged with the library's release version says nothing about
which commit of that library it holds, and a release that is years old may
predate fixes on the paths this app takes (issue #41). Whichever way the
library arrives, the test that proves the decoder should encode with the same
library, configured the way the firmware configures it: bytes recorded once and
trusted forever are not a test of a codec.

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
- **An endpoint the phone answers is not one the phone may send.** A ping to
  endpoint 2001 puts a modal "Ping" dialog in front of the reader every time —
  `prv_push_window` in `services/ping/service.c`, with no flag to suppress it —
  so it belongs to the watch, which sends one an hour and drops a link that goes
  unanswered. Before using an endpoint as a keepalive, read its receive handler
  and check it draws nothing. `system_version_protocol_msg_callback` (endpoint
  16) is the silent one, and PRF answers it too.
- **A count and a length byte are on the wire because they are meant to be
  read.** The audio endpoint says how many frames it carried and prefixes each
  with its own length (`audio_endpoint_add_frame`). Today it always sends one, so
  reading the payload as a single blob looks right — and hands a decoder the
  length byte as sound the moment anything sends two.
- **A field with a documented range is not a normalised value.** A
  transcription's confidence is 1 to 100, or 0 for "no value"
  (`services/voice/transcription.h`). Scaling 0...1 across a byte sends 255,
  which means nothing. The firmware reads confidence nowhere at all, so the
  mistake was invisible.
- **The watch's own validator is part of the contract.**
  `transcription_validate` throws out an entire transcription over one empty word
  or one control character in it, and the reader is then told the recognizer
  misbehaved. Send what passes the validator, and where nothing does, say so
  outright instead of sending a shell.
- **A session has a deadline the phone shares.** The voice endpoint allows 8
  seconds to accept a session and 15 for its result (`services/voice/voice.c`);
  decoding, recognizing and interpreting all happen inside the second one. Any
  model that might be downloaded first, or might think for as long as it likes,
  needs a deadline of its own and something to fall back to.
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
