# iPhone photos from Mac terminal

Copy photos off an iPhone over USB on your Mac, into `~/Pictures/iPhone`, or sync them to another machine.

## One-time setup (macOS)

```bash
# needs Homebrew: https://brew.sh
./iphone-photos.sh --setup
```

That installs `libimobiledevice`, **macFUSE**, and `ifuse` (as `gromgit/fuse/ifuse-mac`). If macOS asks: **System Settings → Privacy & Security → allow macFUSE** (reboot if prompted).

On the iPhone: unlock → plug into Mac → tap **Trust**.

## Usage

```bash
chmod +x iphone-photos.sh

# detect the phone
./iphone-photos.sh --list

# copy DCIM → ~/Pictures/iPhone/<timestamp>  (opens Finder when done)
./iphone-photos.sh

# custom folder
./iphone-photos.sh --dest ~/Desktop/iphone-dump

# sync to another host / NAS
./iphone-photos.sh --rsync user@nas:/volume/photos/iphone/

# stuck mount?
./iphone-photos.sh --unmount
```

Flags: `--open` / `--no-open` control whether Finder opens after copy (default: open on Mac).

## Troubleshooting

| Symptom | Fix |
|--------|-----|
| `no iPhone detected` | Unlock + Trust; unplug/replug; `sudo launchctl kickstart -k system/com.apple.usbmuxd` |
| `ifuse failed` | Allow macFUSE in Privacy & Security; re-run `--setup` |
| Empty / missing `DCIM` | Keep phone unlocked during the copy |

## Notes

- Run this on your Mac (USB). A remote cloud agent cannot see your phone.
- HEIC / Live Photos are copied as-is.
- Linux still works (apt: `libimobiledevice-utils ifuse usbmuxd`); default output there is `./iphone-backup/<timestamp>`.
