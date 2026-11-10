# Photo Backup Checker

A Mac app that shows the photos and videos on a USB-connected iPhone and marks which ones are already on your backup drive, byte for byte. It can back up what's missing, tidy up near-copies on the drive, and help you delete from the iPhone only what is safely backed up.

Built for people who aren't technical: the wording in the app is plain English, and never losing a photo comes before everything else.

> **This app is vibe coded.** Almost all of the code was written by an AI coding assistant (Claude Code), steered and tested by a person on a real iPhone and a real backup drive. It has a test suite and strict safety rules (below), but it has not had a professional code review. Keep a second backup of anything you can't afford to lose, and read the code before you trust it with your photos.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain (comes with Xcode 16, or the Command Line Tools: `xcode-select --install`)
- An iPhone connected by USB cable, and an external drive (or any folder) for backups

## Build and open

```sh
git clone https://github.com/MargeryOlethea/photo-backup-checker.git
cd photo-backup-checker
scripts/make-app.sh
```

Open `build/Photo Backup Checker.app`. The app isn't signed by Apple, so the first time, right-click it and choose **Open**.

1. Click **Choose…** and pick the folder on your drive where your photos and videos are kept.
2. Plug in the iPhone, unlock it, and tap **Trust**. The check starts by itself.

The first check reads every matching file once, so it can take a while (about 30–45 minutes for a full phone). Later checks reuse what was learned.

## Try it without an iPhone

```sh
swift scripts/make-demo.swift ~/pbc-demo          # makes a fake phone and drive from the Mac's wallpapers
swift build
PBC_DEMO_PHONE=~/pbc-demo/phone PBC_DEMO_DRIVE=~/pbc-demo/drive .build/debug/PhotoBackupChecker
```

## What the colours mean

- **Green border**: an exact copy is on the drive (same bytes, checked by fingerprint). Only green items can be deleted from the iPhone.
- **Amber border**: a probable copy exists (same date and shape, for example a HEIC that was converted to JPG), but it isn't proven identical. Never deletable.
- **No border**: not backed up.

Badges: `Live`, `Edited`, `Burst` (several files shown as one), `Duplicate`, `Similar`, and `Probably junk` / `Probably keep` / `Not sure` for screenshots (optional, see below).

## Backing up

Select tiles (click to toggle, double-click to preview), then **Back up…**, and type a folder name like `2026-10 Bali`. Files go into that folder as `Bali 01.HEIC`, `Bali 02.MOV`, … A Live Photo's photo and video share a number.

Existing files are never replaced. Each copy is read back from the drive and compared before it turns green. A hidden `.photo-backup-receipt.json` in the folder records what was copied.

## Fixing possible copies (amber)

Click **Fix N…** on the Possible copy card, or select some items and click **Fix possible copies…**. Each item is shown next to its drive file, and the app decides by itself when it can:

- **Replace with the iPhone original**: same picture, and the iPhone's is better. The iPhone original takes the drive file's place (`Bali 7.JPG` → `Bali 7.HEIC`). The old file goes to the drive's Trash, never deleted.
- **Keep the drive's copy**: same picture, and the drive's is better. Nothing is copied; the item turns green and the drive's copy counts as its backup. The app re-checks that drive file on every check and right before deleting from the iPhone.
- **Not sure: compare them**: the pictures look different, or it's a video. Press **Compare…** to see both side by side, then **Same** or **Not the same** (the item goes back to "Not backed up" and is included in your next backup).

## Deleting from the iPhone

Only all-green selections can be deleted. Right before deleting, every copy is checked against the drive again.

The iPhone refuses some deletes from a Mac: any photo that has an edited version, and every video. It reports them as deleted but keeps them. For those, the app copies their names to the clipboard instead, and you run an iPhone Shortcut named **Delete listed photos**:

1. Get Clipboard
2. Split Text by New Lines
3. Repeat with each item: Find Photos where Name is *Repeat Item*, add to a variable
4. Delete Photos (the variable)

A record of everything deleted or handed to the Shortcut is kept in `~/Library/Application Support/PhotoBackupChecker/deleted-from-iphone.txt`.

## Screenshot check (optional)

The app can ask TypeSafe's Jev model whether a screenshot is junk or worth keeping, and which of several similar shots is best. It's off unless you add an API key:

```
~/Library/Application Support/PhotoBackupChecker/jev.key
```

With a key, two kinds of pictures are sent to TypeSafe: screenshots (PNG images with an iPhone screen's shape), and pairs of similar photos that Apple's own scoring on the Mac can't separate. Nothing else leaves the Mac. Without a key, nothing is sent at all. Screenshots and photos can contain private information (balances, chats, addresses, faces), so leave the key out if that worries you.

## Where the app keeps its data

Everything lives in `~/Library/Application Support/PhotoBackupChecker/`: saved fingerprints, thumbnails, your Fix answers, and a `debug.log`. Deleting that folder resets the app; your photos and backups are not touched.

## Tests

```sh
swift run SelfTest      # prints "ALL CHECKS PASSED (n)"
```

## Contributing

Bug reports and pull requests are welcome. Changes reach `main` only through a reviewed pull request. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
