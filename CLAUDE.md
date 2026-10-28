# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS 14+ SwiftUI app (Swift 6 tools, SwiftPM, no Xcode project) that lists the photos/videos on a USB-connected iPhone and marks which ones already exist on a backup drive, byte-for-byte. It can back up selected items to the drive, replace weaker drive copies ("settle"), and delete verified items from the phone. Built for one non-technical user; copy in the UI is plain English and safety (never losing a photo) is the top design constraint.

## Commands

```sh
swift build                      # debug build of all targets
swift run SelfTest               # run the whole test suite (prints "ALL CHECKS PASSED (n)", exit 1 on failure)
scripts/make-app.sh              # release build + wrap into build/Photo Backup Checker.app (icon, Info.plist, ad-hoc codesign)
swift scripts/make-demo.swift <dir>   # generate a fake "phone" and "drive" folder from macOS wallpapers
PBC_DEMO_PHONE=<dir>/phone PBC_DEMO_DRIVE=<dir>/drive .build/debug/PhotoBackupChecker   # run the app without an iPhone
```

Tests are a plain executable, not XCTest. There is no way to run a single test file from the command line; to isolate one, temporarily comment out the other calls in `Sources/SelfTest/main.swift`. Each `*Tests.swift` file exposes one top-level function (`namingTests()`, `await writerTests()`, …) built on the `check` / `checkThrows` / `checkThrowsAsync` helpers in `Check.swift`. New test files must be registered in `main.swift`.

No linter or formatter is configured.

## Architecture

Two targets with a hard boundary:

- **`Core`** (library, Swift 6 strict concurrency): pure logic with no AppKit/SwiftUI and no knowledge of the iPhone. Everything here is testable from `SelfTest`. Phone I/O is abstracted as a `read: (offset, length) async throws -> Data` closure (`CopyJob.read`, `Fingerprint.sha256(readChunk:size:)`).
- **`PhotoBackupChecker`** (app, Swift 5 language mode): `AppModel` (one `@MainActor @Observable` object holding all state and all long-running work), `PhoneSource` (ImageCaptureCore wrapper, also implements demo mode), `Views.swift` (every SwiftUI view), `Snapshot.swift` (file-driven test automation, demo only).

### Core data flow

1. `PhoneSource` turns `ICCameraFile`s into `PhoneItem`s; `Bundler.bundles` groups them into `ItemBundle`s (Live Photo pairs, edited renders + originals, bursts, sidecar `.AAE` files) keyed by `folder/stem`.
2. `DriveIndex` (actor) walks the drive, reuses cached `DriveFile`s by `(path, size, mtime)`, and SHA-256s only drive files whose size matches some phone file.
3. `AppModel.runCheck` fingerprints phone files that share a size with a drive file (or with another phone file, for duplicate detection), then `Matcher.status` decides per item: `.verified` (same size + same hash) / `.possible` (capture date within 1 s plus same aspect ratio or duration) / `.none`. `Matcher.bundleStatus` rolls members up: a bundle is only green if every media member is green.
4. Clean-up: `Cleanup.exactDuplicates` by hash, `Cleanup.similarGroups` via Vision feature prints within a 10-minute window, `BestPick` scores each similar group (Vision aesthetics + face quality); close calls optionally go to Jev (TypeSafe API).

### Safety invariants (do not weaken)

- Only `.verified` bundles are deletable (`Matcher.isDeletable`). `DeleteGate.verify` re-hashes the drive copy immediately before each delete, and `deleteSelected` requires a hash read from the phone *this session* (`sessionHashes`, not `hashCache`).
- One exception to "green = byte-identical", chosen by the owner: a possible copy whose drive version is better can be kept as its backup (`Settle.Decision.keepDrive`, saved in `settle-decisions.json`). It is green only while the drive file's fingerprint equals the one stored when kept (re-hashed on every check, `Settle.applying`), and the delete gate checks it against that fingerprint and size (`DeleteCandidate.keptSizes`). One drive file never stands in for two iPhone photos.
- Settling a possible copy never deletes: `Settle.suggested(for:)` maps a verdict to Replace (old copy to Trash) or Keep drive; unsure verdicts (`differentPhoto`, `sameClip`) need the person's Compare (`Settle.reconciled`). "Not the same" (`Decision.different`) only clears that one match to Not backed up. `AppModel.settle` only acts on rows whose drive file is unchanged since it was compared (`SettleRow.identity`).
- `BackupWriter.copy` streams to a hidden staging file, fsyncs, re-reads and re-hashes it, then places it with `renamex_np(RENAME_EXCL)` → `link` → exclusive-create fallback. Existing drive files are never overwritten; `BackupError.nameTaken` is thrown instead. `Settle.replace` moves the old copy to the Trash, never deletes it.
- Hash caches are keyed `"id|size|captureDate"` (`cacheKey`) so a re-shot file at the same path never reuses a stale hash. Device-scoped data (thumbnails, prints, Jev verdicts, scores) is additionally prefixed with the phone's persistent ID (`deviceKey`).
- `DriveIndex.save` refuses to write unless a full scan completed, so an interrupted scan can't shrink the cache.

### Work model

`AppModel.startWork` runs at most one `Task` at a time (`work`/`workID`); `busy` gates every mutating button. `resilient(drive:phone:)` wraps each step: if the drive or phone disappears it sets `pause` and retries the same step on reconnect, so unplugging mid-operation never fails the job. Phone reads and deletes go through `Timeout.callback` (ends at once on Stop); `HangTracker` decides whether a timed-out file is skipped or the user is asked to replug.

### Persistence

Everything lives in `~/Library/Application Support/PhotoBackupChecker/` (demo mode uses a `demo/` subfolder wiped on launch): `drive-index.json`, `phone-hashes.json`, `jev-verdicts.json`, `similar-prints.json`, `shot-scores.json`, `jev-picks.json`, `settle-decisions.json`, `bad-renders.json`, `thumbs/`, `debug.log`, `deleted-from-iphone.txt`, and the optional `jev.key`. The chosen drive folder is in `UserDefaults` key `driveRoot`; the default is the user's specific external volume path in `AppModel.init`. Each backup folder on the drive gets a `.photo-backup-receipt.json`.

### Conventions

- Swift 6 `Core` means closures passed across actors must be `@Sendable`; test hooks on `BackupWriter` are `nonisolated(unsafe)` statics.
- Views read `model.phoneState` to force refresh on phone events because `PhoneSource` is not `@Observable`.
- `ActiveSheet` is the single source of truth for which sheet is open; add new sheets there.
- User-facing strings avoid jargon ("fingerprint" not "hash", "hard disk" not "volume"). Keep that tone.
