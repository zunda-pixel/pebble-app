# Pebble App — AI Handoff

Updated: 2026-08-25 (Asia/Tokyo)

## Current state

- Repository: `zunda-pixel/pebble-app`
- Working branch: `pebble-app-implementation`
- Base branch: `main`
- Pull request: [#1 Implement Pebble companion app](https://github.com/zunda-pixel/pebble-app/pull/1)
- Current handoff commit before this document: `2cd1e0e` (`Add localization string catalogs`)
- The feature branch contains 41 implementation commits relative to `main`.
- The local `main` branch was reset to and tracks `origin/main`; unmerged work is retained on `pebble-app-implementation`.
- The feature branch exists on GitHub. Its upstream is not configured locally because the sandbox blocked the local `.git/config` update during `git push -u`; use an explicit push (`git push origin pebble-app-implementation`) or configure upstream if permissions allow.

## What has been implemented

This PR builds a native Apple-platform Pebble companion app and Swift package. Major areas include:

- CoreBluetooth discovery, connection state, reconnection, battery reporting, watch-version requests, and time synchronization.
- Pebble protocol framing, PPoG transport, ping/pong health checks, PutBytes transfer, AppMessage, BlobDB, app fetch/reorder/run-state, and system-message codecs.
- PBW/PBZ parsing and importing, local app/watch library persistence, app installation/removal/reordering, firmware update and recovery flows.
- Timeline pins/actions/notifications, notification delivery, app configuration, diagnostics, catalog support, QEMU client support, and background synchronization.
- Calendar and HealthKit bridges, health-data logging/import/export/synchronization.
- SwiftUI companion interface for watch management, apps/watchfaces, timeline, health, catalog, firmware, diagnostics, settings, and onboarding.
- API/unit tests, SwiftUI tests, and an XCUIAutomation test target.
- App and package string catalogs.

The implementation was developed with reference to the Core Devices mobile app repository:
https://github.com/coredevices/mobileapp

## Project layout

- `Pebble.xcodeproj`: app project and automation-test target.
- `Pebble/MainApp.swift`: app entry point and scene setup.
- `Pebble/Pebble.entitlements`: app capabilities.
- `PebbleKit/Package.swift`: local Swift package definition.
- `PebbleKit/Sources/API`: Bluetooth, protocol, persistence, firmware, application, timeline, diagnostics, QEMU, and companion-service code.
- `PebbleKit/Sources/UI/AppModel.swift`: primary observable application state and orchestration.
- `PebbleKit/Sources/UI/ContentView.swift`: main SwiftUI interface.
- `PebbleKit/Sources/UI/PebbleCompanionRuntime.swift`: runtime/service integration.
- `PebbleKit/Sources/UI/CalendarBridge.swift` and `HealthKitBridge.swift`: system-framework adapters.
- `PebbleKit/Tests/APITests` and `PebbleKit/Tests/UITests`: Swift Testing suites.
- `PebbleUIAutomationTests`: XCUIAutomation tests.

## Validation completed

- Xcode `BuildProject` completed successfully on 2026-08-25 after package-resource cleanup.
- Final reported result: project built successfully with no build errors.
- The PR description records the successful Xcode build.
- 2026-08-25 (later session): `APITests` (69 tests) and `UITests` (7 tests) both pass via Xcode test schemes.
- `PebbleUIAutomationTests` fails with "The app representing com.zunda.Pebble could not be found": the UI-testing target has no `TEST_TARGET_NAME` and no dependency on the `Pebble` app target. This must be fixed in Xcode's target editor (General > Target Application), not by editing the pbxproj directly.

## Bug fixes applied on 2026-08-25 (later session)

- `PebbleCompanionRuntime.swift`: the PebbleKit JS shim emitted bare identifiers (`platformLiteral` etc.) instead of Swift string interpolations, so `Pebble.getActiveWatchInfo()`, `getAccountToken()`, and `getWatchToken()` threw `ReferenceError` in real PBW configuration pages. Fixed with `\(...)`.
- `PebbleDiagnostics.swift`: `firmwareVersion` (`String?`) was interpolated directly into the diagnostics report, producing `Optional("…")`. Now falls back to `"unknown"`.
- `ENABLE_RESOURCE_ACCESS_CALENDARS` build setting changed `NO` → `YES` (both configurations) so EventKit calendar/reminder sync works under the macOS sandbox.
- Verified against the reference implementation (libpebble3) and intentionally NOT changed: `AppFetchResponseStatus.noData` wire value `0x01` (matches `AppFetch.kt` `NO_DATA(0x01u)`), and the PPoG handshake's resetComplete-in-response-to-resetComplete write (matches `PPoG.kt:127-129`).

## Recently fixed build issue

Xcode initially reported `Missing package product 'PebbleKit'`. The underlying Swift package resolution error was:

> multiple resources named 'Localizable.xcstrings' in target 'UI'

There were two identical catalogs:

- `PebbleKit/Sources/UI/Resources/Localizable.xcstrings` (kept)
- `PebbleKit/Sources/UI/Resources/Other Resources/Localizable.xcstrings` (removed/moved to Trash)

Do not reintroduce the second catalog with the same resource name, or SwiftPM package resolution will fail again.

## Suggested next work

1. Check PR #1 for CI results, review comments, merge conflicts, and requested changes.
2. Re-run the full build after any concurrent-agent edits; this workspace may be modified by other agents.
3. Run the Swift package test suites and the XCUIAutomation target. A successful project build is confirmed, but this handoff does not claim a fresh full test-suite pass.
4. Exercise Bluetooth pairing/reconnection and protocol behavior with supported Pebble hardware.
5. Exercise firmware update/recovery with safe test devices and representative PBZ packages.
6. Verify notification, Calendar, HealthKit, background execution, network, and sandbox permission flows on device and macOS as applicable.
7. Review localization completeness and translation states; the current catalogs are primarily source-language catalogs.
8. Confirm signing team, entitlements, deployment targets, and archive settings before distribution.

## Useful commands

```sh
git switch pebble-app-implementation
git status --short --branch
git log --oneline main..HEAD
git push origin pebble-app-implementation
gh pr view 1
gh pr checks 1
```

Prefer Xcode's `BuildProject` for full builds and `XcodeRefreshCodeIssuesInFile` for quick Swift diagnostics when operating through the Xcode coding assistant.

## Cautions for the next AI

- Preserve unrelated or concurrent changes; inspect `git status` before editing.
- The PR is large and introduces the project from an effectively empty `main`, so review by subsystem rather than treating it as a small patch.
- Avoid force-pushing or rewriting the 41-commit branch unless the user explicitly requests it.
- Do not add duplicate `Localizable.xcstrings` resources to the `UI` SwiftPM target.
- Hardware, Bluetooth permissions, HealthKit, Calendar, notifications, signing, and firmware operations require environment/device validation beyond compilation.
