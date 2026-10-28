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

Click **Fix N…** on the Possible copy card to see every amber item, or select some items and click **Fix possible copies…** (or **Fix…** in a preview) to see only those. Each item is shown next to its drive file, and the app decides by itself when it can:

- **Replace with the iPhone original**: same picture, and the iPhone's is better. The iPhone original takes the drive file's place, keeping its name with the iPhone's format (`Bali 7.JPG` → `Bali 7.HEIC`). The old file goes to the drive's Trash.
- **Keep the drive's copy**: same picture, and the drive's is better (more pixels, then bigger file). Nothing is copied; the item turns green and the drive's copy counts as its backup. The app remembers this and re-checks that drive file (fingerprint) on every check and right before deleting from the iPhone. A Live Photo's video is still copied if the drive doesn't have it.
- **Not sure: compare them**: the pictures look different, or it's a video (matched by date and length only). Press **Compare…** to see both big, side by side, then **Same** (settled as above) or **Not the same** (the item turns grey, "Not backed up", and goes with your next backup). The app remembers "Not the same".

Untick an item to leave it amber. Press **Fix N**.

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
