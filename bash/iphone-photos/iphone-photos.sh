#!/usr/bin/env bash
# Mount an iPhone over USB and copy (or sync) its photos.
# Tuned for macOS (Homebrew + macFUSE + ifuse). Also works on Linux.
#
# Usage:
#   ./iphone-photos.sh                     # copy DCIM -> ~/Pictures/iPhone/<date>
#   ./iphone-photos.sh --dest ~/Desktop/iphone
#   ./iphone-photos.sh --rsync user@host:/photos/iphone
#   ./iphone-photos.sh --list              # list connected devices only
#   ./iphone-photos.sh --unmount           # unmount if still mounted
#   ./iphone-photos.sh --setup             # install macOS deps via Homebrew

set -euo pipefail

OS="$(uname -s)"
MOUNT_DIR="${IPHONE_MOUNT_DIR:-${HOME}/.iphone-mount}"
if [[ "$OS" == "Darwin" ]]; then
  DEFAULT_DEST="${HOME}/Pictures/iPhone/$(date +%Y-%m-%d_%H%M%S)"
else
  DEFAULT_DEST="./iphone-backup/$(date +%Y-%m-%d_%H%M%S)"
fi
DEST=""
RSYNC_TARGET=""
MODE="copy"
OPEN_AFTER=0
[[ "$OS" == "Darwin" ]] && OPEN_AFTER=1

die() { echo "error: $*" >&2; exit 1; }
info() { echo "$*"; }

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    if [[ "$OS" == "Darwin" ]]; then
      die "missing '$1'. Run: ./iphone-photos.sh --setup"
    fi
    die "missing '$1'. Install libimobiledevice + ifuse (see README)."
  fi
}

is_mounted() {
  # macOS has no reliable mountpoint(1); parse mount output instead.
  mount | grep -F " on ${MOUNT_DIR} " >/dev/null 2>&1
}

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

setup_mac() {
  [[ "$OS" == "Darwin" ]] || die "--setup is for macOS only"
  command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install from https://brew.sh then re-run --setup"

  info "installing libimobiledevice, macFUSE, and ifuse..."
  brew install libimobiledevice
  brew install --cask macfuse
  # homebrew-core's ifuse is Linux-only; the macFUSE build lives in the gromgit/fuse tap
  brew install gromgit/fuse/ifuse-mac

  info ""
  info "If macFUSE asks for permission: System Settings → Privacy & Security → allow macFUSE, then reboot if prompted."
  info "Then: unlock iPhone → USB → Trust → ./iphone-photos.sh --list"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --setup) setup_mac ;;
    --list) MODE="list"; shift ;;
    --unmount) MODE="unmount"; shift ;;
    --dest) DEST="${2:-}"; [[ -n "$DEST" ]] || die "--dest needs a path"; shift 2 ;;
    --rsync) RSYNC_TARGET="${2:-}"; [[ -n "$RSYNC_TARGET" ]] || die "--rsync needs a target"; MODE="rsync"; OPEN_AFTER=0; shift 2 ;;
    --open) OPEN_AFTER=1; shift ;;
    --no-open) OPEN_AFTER=0; shift ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

need idevice_id
need ifuse

unmount_phone() {
  if is_mounted; then
    if [[ "$OS" == "Darwin" ]]; then
      umount "$MOUNT_DIR" 2>/dev/null || diskutil unmount "$MOUNT_DIR" 2>/dev/null || true
    elif command -v fusermount >/dev/null 2>&1; then
      fusermount -u "$MOUNT_DIR" || umount "$MOUNT_DIR" || true
    else
      umount "$MOUNT_DIR" || true
    fi
    info "unmounted $MOUNT_DIR"
  else
    info "nothing mounted at $MOUNT_DIR"
  fi
}

if [[ "$MODE" == "unmount" ]]; then
  unmount_phone
  exit 0
fi

# usbmuxd tip on Mac: restart if device invisible after sleep
DEVICES="$(idevice_id -l 2>/dev/null || true)"
if [[ -z "$DEVICES" ]]; then
  if [[ "$OS" == "Darwin" ]]; then
    die "no iPhone detected.
  1) Unlock iPhone, plug USB-C/Lightning cable into the Mac
  2) Tap Trust (enter passcode)
  3) Retry: ./iphone-photos.sh --list
  Still blank? Try: sudo launchctl kickstart -k system/com.apple.usbmuxd   (or unplug/replug)"
  fi
  die "no iPhone detected. Unlock the phone, plug in USB, tap Trust, then retry."
fi

info "connected device(s):"
echo "$DEVICES" | sed 's/^/  /'

if [[ "$MODE" == "list" ]]; then
  ideviceinfo 2>/dev/null | grep -E '^(DeviceName|ProductType|ProductVersion|SerialNumber):' || true
  exit 0
fi

mkdir -p "$MOUNT_DIR"
if is_mounted; then
  info "already mounted at $MOUNT_DIR"
else
  info "mounting phone at $MOUNT_DIR ..."
  if ! ifuse "$MOUNT_DIR"; then
    if [[ "$OS" == "Darwin" ]]; then
      die "ifuse failed.
  • Unlock phone + Trust this Mac
  • Confirm macFUSE is allowed (System Settings → Privacy & Security)
  • Re-run ./iphone-photos.sh --setup if packages are missing"
    fi
    die "ifuse failed. Unlock phone + Trust this computer, then retry."
  fi
fi

trap 'unmount_phone' EXIT

DCIM="$MOUNT_DIR/DCIM"
if [[ ! -d "$DCIM" ]]; then
  die "no DCIM folder found. Keep the iPhone unlocked, open Photos once, then retry."
fi

PHOTO_COUNT="$(find "$DCIM" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png' -o -iname '*.mov' -o -iname '*.mp4' -o -iname '*.dng' \) 2>/dev/null | wc -l | tr -d ' ')"
info "found ~$PHOTO_COUNT media files under DCIM"

if [[ "$MODE" == "rsync" ]]; then
  need rsync
  info "rsync -> $RSYNC_TARGET"
  rsync -avh --progress "$DCIM/" "$RSYNC_TARGET"
  info "done."
  exit 0
fi

DEST="${DEST:-$DEFAULT_DEST}"
mkdir -p "$DEST"
info "copying DCIM -> $DEST"
if command -v rsync >/dev/null 2>&1; then
  rsync -avh --progress "$DCIM/" "$DEST/"
else
  cp -R "$DCIM/." "$DEST/"
fi

info "done. photos are in: $DEST"
if [[ "$OPEN_AFTER" -eq 1 ]] && command -v open >/dev/null 2>&1; then
  open "$DEST"
fi
info "phone will unmount on exit."
