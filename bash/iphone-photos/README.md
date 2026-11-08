# iPhone photos from Mac terminal

Import photos and videos off an iPhone over USB on your Mac, sorted as they are copied:

```
~/Desktop/iphone-photos/
  Screenshots/2026/2026-10-13_001535_IMG_5588.PNG
  2026/Japan/Tokyo/2026-11-03_144646_IMG_5640.HEIC
  2026/Japan/Hyogo/...                ← Kobe is in Hyogo prefecture
  2024/India/Delhi/...
  2026/Unknown location/...           ← no GPS saved in the file
```

- **Screenshots** are recognised by the tag iOS writes into them.
- **Year** comes from when the photo/video was taken.
- **Country / state** comes from the GPS inside the file, looked up **offline** in the free GeoNames database (downloaded once to `~/.cache/iphone-photos`). Locations never leave the Mac.
- Files are renamed `<YYYY-MM-DD_HHMMSS>_<original name>`. Live Photo videos and `.AAE` edit files go next to their photo with the same date.
- Uses `afcclient` from libimobiledevice, so there is **no macFUSE, kernel extension, or security change** needed.

## One-time setup (macOS)

```bash
# needs Homebrew: https://brew.sh
./iphone-photos.sh --setup
```

That installs `libimobiledevice` and `exiftool`, and downloads the place-name database (~11 MB). Python 3 from macOS is used for sorting (`sort_photos.py`, keep it next to the script).

On the iPhone: unlock → plug into Mac → tap **Trust**.

## Usage

```bash
# detect the phone
./iphone-photos.sh --list

# practice run on the next 200 photos: shows where they'd go, sorts nothing
./iphone-photos.sh --dry-run --limit 200

# import everything new; asks which folder (Enter = the folder used last time,
# first time ~/Desktop/iphone-photos). You can drag a folder from Finder into the terminal.
./iphone-photos.sh

# or give the folder directly, e.g. an external drive
./iphone-photos.sh /Volumes/MyDrive/iPhone

# import, then sync the library to another host / NAS
./iphone-photos.sh --rsync user@nas:/volume/photos/iphone/
```

Re-running into the **same folder** only imports photos that are new on the phone (the last folder used is remembered in `~/.config/iphone-photos/last-dest`). A list of what was imported is kept in `.iphone-photos-imported.tsv` inside the library, so photos you delete on the Mac are **not** copied back. Use `--reimport` to copy them again (files already in the library are not duplicated).

A practice run keeps what it downloaded in a hidden `.incoming` folder, so the real run doesn't download it again.

Flags: `--open` / `--no-open` control whether Finder opens after the import (default: open on Mac).

## Troubleshooting

| Symptom | Fix |
|--------|-----|
| `no iPhone detected` | Unlock + Trust; unplug/replug; `sudo launchctl kickstart -k system/com.apple.usbmuxd` |
| `could not read DCIM` | Keep phone unlocked; re-tap Trust |
| `N item(s) failed` | Keep phone unlocked and re-run the same command; only missing files are copied |
| Photo in `Unknown location` | The file has no GPS (location off, saved from an app, or a download) |

## Notes

- Run this on your Mac (USB). A remote cloud agent cannot see your phone.
- HEIC / Live Photos are copied as-is.
- Places farther than 100 km from any town (e.g. mid-ocean) go to `Unknown location`.
- Linux works too with libimobiledevice 1.3+, exiftool and python3 (apt: `libimobiledevice-utils usbmuxd libimage-exiftool-perl`); default library there is `./iphone-photos`.
- Installed macFUSE for an older version of this script? Remove it with `brew uninstall ifuse-mac && brew uninstall --cask macfuse`.
