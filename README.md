# Photo Backup Checker

A Mac app that shows the photos and videos on a USB-connected iPhone and marks which ones are already on the backup drive.

## Colours

- **Green border**: an exact copy is on the drive (same bytes, checked by fingerprint). Only green items can be deleted from the phone.
- **Amber border**: a probable copy exists (same date and shape, e.g. a converted HEIC→JPG), but it isn't proven identical. Never deletable.
- **No border**: not backed up.

Badges: `Live`, `Edited`, `Burst` (several files shown as one), `Duplicate`, `Similar`, and Jev's `Probably junk` / `Probably keep` / `Not sure` for screenshots.

## Build and open

```sh
scripts/make-app.sh
```

Open `build/Photo Backup Checker.app`. The first time, right-click it → **Open** (it's your own app, not from the App Store).

Plug in the iPhone, unlock it, tap **Trust**. The check starts by itself. The first check reads every matching file once, so expect it to take a while (about 30–45 min). Later checks reuse what was learned.

## Backing up

Select tiles (click to toggle, double-click to preview) → **Back up selected…** → type a folder name like `2026-10 Bali`. Files go to `Memories/2026-10 Bali/` as `Bali 01.HEIC`, `Bali 02.MOV`… A Live Photo's photo and video share a number. Existing files are never replaced. Each copy is re-read from the drive and compared before it turns green. A hidden `.photo-backup-receipt.json` in the folder records what was copied.

## Fixing possible copies (amber)

Click **Fix N…** on the Possible copy card (or **Fix on drive…** in a preview). Each amber item is shown next to its drive file with a suggested action:

- **Replace**: the iPhone original takes the drive file's place, keeping its name with the iPhone's format (`Bali 7.JPG` → `Bali 7.HEIC`). The old file goes to the drive's Trash. Suggested when it is the same picture and the iPhone's is better.
- **Keep both**: the iPhone original is added next to the drive file (`Bali 7.HEIC`, or `Bali 7 (from iPhone).HEIC` if that name is taken). Suggested when the drive's copy is bigger, or when they don't look like the same picture.
- **Skip**: leave it amber.

Press **Fix N**. Every copy is verified after writing, so the items turn green. Live Photos bring their video and any edit file along. Videos are matched by date and length only, so they default to **Keep both**.

## Deleting from the phone

Only all-green selections can be deleted. Right before deleting, every copy is checked against the drive again. Deleting this way may not go to the phone's Recently Deleted. If the phone doesn't allow deleting from the Mac, the button becomes **Ready-to-delete list**.

## Jev (screenshot check)

Put your TypeSafe key in:

```
~/Library/Application Support/PhotoBackupChecker/jev.key
```

Only screenshots (PNG at the iPhone 13's screen size) are sent to TypeSafe. Normal photos never leave the Mac. Screenshots can contain private information (balances, chats, addresses).

## Tests

```sh
swift run SelfTest
```
