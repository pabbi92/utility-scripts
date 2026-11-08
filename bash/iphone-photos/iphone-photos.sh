#!/usr/bin/env bash
# Import an iPhone's photos and videos over USB, sorted as they are copied:
#   Screenshots/<year>/   <year>/<country>/<state>/   <year>/Unknown location/
# Files are renamed to <YYYY-MM-DD_HHMMSS>_<original name>.
# Uses libimobiledevice's afcclient, so no macFUSE or kernel extension is needed.
#
# Usage:
#   ./iphone-photos.sh                     # asks where to import (Enter = last folder used)
#   ./iphone-photos.sh ~/Desktop/photos    # import into this folder
#   ./iphone-photos.sh --dest ~/Desktop/photos   # same as above
#   ./iphone-photos.sh --dry-run           # practice run: show where files would go, move nothing
#   ./iphone-photos.sh --limit 200         # only import the next 200 new photos
#   ./iphone-photos.sh --rsync user@host:/photos/iphone
#   ./iphone-photos.sh --reimport          # also re-copy photos imported before (e.g. deleted on the Mac)
#   ./iphone-photos.sh --list              # list connected devices only
#   ./iphone-photos.sh --setup             # install macOS deps via Homebrew
#
# Re-running only imports photos that are new on the phone.

set -euo pipefail

OS="$(uname -s)"
if [[ "$OS" == "Darwin" ]]; then
  DEFAULT_LIB="${HOME}/Desktop/iphone-photos"
else
  DEFAULT_LIB="./iphone-photos"
fi
LAST_DEST_FILE="${HOME}/.config/iphone-photos/last-dest"
GEONAMES="${IPHONE_GEONAMES_DIR:-${HOME}/.cache/iphone-photos/geonames}"
SORTER="$(cd "$(dirname "$0")" && pwd)/sort_photos.py"
DEST=""
RSYNC_TARGET=""
MODE="import"
DRY_RUN=0
REIMPORT=0
LIMIT=0
OPEN_AFTER=0
[[ "$OS" == "Darwin" ]] && OPEN_AFTER=1

die() { echo "error: $*" >&2; exit 1; }
info() { echo "$*"; }

# Redraw the current status line in a terminal; elsewhere only the final line matters.
if [[ -t 1 ]]; then
  progress() { printf '\r%s\033[K' "$1"; }
  finish() { printf '\r%s\033[K\n' "$1"; }
else
  progress() { :; }
  finish() { echo "$1"; }
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    if [[ "$OS" == "Darwin" ]]; then
      die "missing '$1'. Run: ./iphone-photos.sh --setup"
    fi
    die "missing '$1'. Install libimobiledevice 1.3+, exiftool and python3 (see README)."
  fi
}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit 0
}

ensure_geonames() {
  [[ -s "$GEONAMES/cities1000.txt" && -s "$GEONAMES/admin1CodesASCII.txt" && -s "$GEONAMES/countryInfo.txt" ]] && return 0
  need curl
  need unzip
  info "downloading the offline place-name database (GeoNames, ~11 MB, one time)..."
  mkdir -p "$GEONAMES"
  local f
  for f in cities1000.zip admin1CodesASCII.txt countryInfo.txt; do
    curl -fsSL -o "$GEONAMES/$f" "https://download.geonames.org/export/dump/$f" || die "could not download $f"
  done
  unzip -o -q "$GEONAMES/cities1000.zip" -d "$GEONAMES" && rm -f "$GEONAMES/cities1000.zip"
}

setup_mac() {
  [[ "$OS" == "Darwin" ]] || die "--setup is for macOS only"
  command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install from https://brew.sh then re-run --setup"

  info "installing libimobiledevice and exiftool..."
  brew install libimobiledevice exiftool
  ensure_geonames

  info ""
  info "Then: unlock iPhone → USB → Trust → ./iphone-photos.sh --list"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --setup) setup_mac ;;
    --list) MODE="list"; shift ;;
    --dry-run) DRY_RUN=1; OPEN_AFTER=0; shift ;;
    --reimport) REIMPORT=1; shift ;;
    --limit) LIMIT="${2:-}"; [[ "$LIMIT" =~ ^[0-9]+$ && "$LIMIT" -gt 0 ]] || die "--limit needs a number"; shift 2 ;;
    --dest) DEST="${2:-}"; [[ -n "$DEST" ]] || die "--dest needs a path"; shift 2 ;;
    --rsync) RSYNC_TARGET="${2:-}"; [[ -n "$RSYNC_TARGET" ]] || die "--rsync needs a target"; OPEN_AFTER=0; shift 2 ;;
    --open) OPEN_AFTER=1; shift ;;
    --no-open) OPEN_AFTER=0; shift ;;
    -*) die "unknown arg: $1 (try --help)" ;;
    *) [[ -z "$DEST" ]] || die "only one destination folder allowed (got '$DEST' and '$1')"; DEST="$1"; shift ;;
  esac
done

need idevice_id
need afcclient

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
UDID="$(echo "$DEVICES" | head -1)"
if [[ "$(echo "$DEVICES" | wc -l | tr -d ' ')" -gt 1 ]]; then
  info "using the first one: $UDID"
fi

if [[ "$MODE" == "list" ]]; then
  ideviceinfo -u "$UDID" 2>/dev/null | grep -E '^(DeviceName|ProductType|ProductVersion|SerialNumber):' || true
  exit 0
fi

need exiftool
need python3
[[ -f "$SORTER" ]] || die "missing $SORTER (keep it next to this script)"
[[ -n "$RSYNC_TARGET" ]] && need rsync
ensure_geonames

# afcclient exits 0 even when a command fails, so errors are detected from its output.
afc() { afcclient -u "$UDID" -- "$@" 2>&1; }

if [[ "$OS" == "Darwin" ]]; then
  local_sizes() { (cd "$1" && find . -maxdepth 1 -type f -exec stat -f '%z %N' {} +); }
else
  local_sizes() { (cd "$1" && find . -maxdepth 1 -type f -exec stat -c '%s %n' {} +); }
fi

# Tidy a typed or Finder-dragged path: trim spaces and quotes, expand a leading ~.
clean_path() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  p="${p#[\"\']}"
  p="${p%[\"\']}"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  printf '%s' "$p"
}

if [[ -z "$DEST" ]]; then
  suggested="$DEFAULT_LIB"
  [[ -s "$LAST_DEST_FILE" ]] && suggested="$(cat "$LAST_DEST_FILE")"
  if [[ -t 0 ]]; then
    info ""
    info "Where should the photos go? Type a folder path, or drag a folder from Finder here."
    info "Use the same folder as last time so only new photos are copied."
    # Plain `read` (no -r) turns Finder's "My\ Folder" into "My Folder".
    read -p "Folder [$suggested]: " answer || answer=""
    DEST="$(clean_path "${answer:-}")"
  fi
  DEST="${DEST:-$suggested}"
fi
DEST="$(clean_path "$DEST")"
mkdir -p "$DEST" || die "could not create folder: $DEST"
LIB="$(cd "$DEST" && pwd)"
mkdir -p "$(dirname "$LAST_DEST_FILE")" && printf '%s\n' "$LIB" > "$LAST_DEST_FILE"

MANIFEST="$LIB/.iphone-photos-imported.tsv"
STAGE="$LIB/.incoming/$UDID"
mkdir -p "$STAGE"
touch "$MANIFEST"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Decide what to fetch for one DCIM folder.
# Inputs: already-imported "<name>\t<size>" ($1), staged sizes ($2), afcclient `ls -l` ($3).
# Writes: process list (new files, honouring --limit by photo number), afcclient get
# commands for the ones not yet staged, and touch -t stamps. Prints "<total> <new> <fetch>".
plan_folder() {
  awk -v folder="$4" -v limit="$5" -v reimport="$REIMPORT" \
      -v process="$WORK/process" -v cmds="$WORK/cmds" -v stamps="$WORK/stamps" '
    BEGIN {
      split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
      for (i = 1; i <= 12; i++) mon[m[i]] = sprintf("%02d", i)
      printf "" > process; printf "" > cmds; printf "" > stamps
    }
    FILENAME == ARGV[1] { done[$1 "\t" $2] = 1; next }
    FILENAME == ARGV[2] {
      name = $2; for (i = 3; i <= NF; i++) name = name " " $i
      sub(/^\.\//, "", name); have[name] = $1; next
    }
    $1 ~ /^-/ {
      name = $10; for (i = 11; i <= NF; i++) name = name " " $i
      total++
      if (!reimport && ((name "\t" $5) in done)) next
      base = name; sub(/\.[^.]*$/, "", base)
      if (base != last) { groups++; last = base }
      if (limit > 0 && groups > limit) next
      new++
      print name "\t" $5 > process
      if ((name in have) && have[name] == $5) next
      fetch++
      print "get -f /DCIM/" folder "/" name " " name > cmds
      split($9, t, ":")
      printf "%s%s%02d%s%s.%s %s\n", $8, mon[$7], $6, t[1], t[2], t[3], name > stamps
    }
    END {
      used = groups
      if (limit > 0 && used > limit) used = limit
      printf "%d %d %d %d\n", total, new, fetch, used
    }
  ' "$1" "$2" "$3"
}

afc ls -l /DCIM > "$WORK/dcim"
if grep -q 'Error' "$WORK/dcim"; then
  die "could not read DCIM: $(grep 'Error' "$WORK/dcim" | head -1)
  Keep the iPhone unlocked and trusted, then retry."
fi
FOLDERS="$(awk '$1 ~ /^d/ && $10 !~ /^\./ { print $10 }' "$WORK/dcim" | sort)"
[[ -n "$FOLDERS" ]] || die "no photo folders found in DCIM. Keep the iPhone unlocked, open Photos once, then retry."

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "practice run: nothing will be sorted (downloads are kept so the real run is faster)"
fi
info "importing into $LIB"
: > "$WORK/summary"
SORTED=0
FAILED=0
TOTAL=0
REMAINING="$LIMIT"
while read -r folder; do
  if [[ "$LIMIT" -gt 0 && "$REMAINING" -le 0 ]]; then
    break
  fi
  afc ls -l "/DCIM/$folder" | sort -k10 > "$WORK/remote"
  if grep -q 'Error' "$WORK/remote"; then
    info "  $folder: could not list ($(grep 'Error' "$WORK/remote" | head -1))"
    FAILED=$((FAILED + 1))
    continue
  fi

  awk -F'\t' -v u="$UDID" -v f="$folder" '$1 == u && $2 == f { print $3 "\t" $4 }' "$MANIFEST" > "$WORK/done"
  mkdir -p "$STAGE/$folder"
  local_sizes "$STAGE/$folder" > "$WORK/local"
  read -r total new fetch groups < <(plan_folder "$WORK/done" "$WORK/local" "$WORK/remote" "$folder" "$REMAINING")
  TOTAL=$((TOTAL + total))
  [[ "$LIMIT" -gt 0 ]] && REMAINING=$((REMAINING - groups))
  if [[ "$new" -eq 0 ]]; then
    info "  $folder: $total files, nothing new"
    continue
  fi
  status="  $folder: $total files, $new new ..."
  progress "$status"

  if [[ "$fetch" -gt 0 ]]; then
    before="$(find "$STAGE/$folder" -type f | wc -l | tr -d ' ')"
    (cd "$STAGE/$folder" && { cat "$WORK/cmds"; echo exit; } | afcclient -u "$UDID" > "$WORK/getlog" 2>&1) &
    getpid=$!
    while kill -0 "$getpid" 2>/dev/null; do
      now="$(find "$STAGE/$folder" -type f | wc -l | tr -d ' ')"
      progress "$status downloading $((now - before))/$fetch"
      sleep 1
    done
    wait "$getpid" || true
    progress "$status sorting"
    while read -r stamp name; do
      [[ -f "$STAGE/$folder/$name" ]] && touch -t "$stamp" "$STAGE/$folder/$name" 2>/dev/null || true
    done < "$WORK/stamps"
  fi

  local_sizes "$STAGE/$folder" > "$WORK/local"
  : > "$WORK/process.ok"
  missing="$(awk -v ok="$WORK/process.ok" '
    FILENAME == ARGV[1] { n = $2; for (i = 3; i <= NF; i++) n = n " " $i; sub(/^\.\//, "", n); have[n] = $1; next }
    { split($0, c, "\t"); if ((c[1] in have) && have[c[1]] == c[2]) print > ok; else bad++ }
    END { print bad + 0 }' "$WORK/local" "$WORK/process")"

  dry=()
  [[ "$DRY_RUN" -eq 1 ]] && dry=(--dry-run)
  result="$(python3 "$SORTER" --staging "$STAGE/$folder" --files "$WORK/process.ok" --library "$LIB" \
    --manifest "$MANIFEST" --udid "$UDID" --folder "$folder" --geonames "$GEONAMES" \
    --summary "$WORK/summary" ${dry[@]+"${dry[@]}"})" || die "sorting failed in $folder (downloads kept; re-run to retry)"
  read -r placed existing <<< "$result"
  rm -f "$WORK/process.ok"

  SORTED=$((SORTED + placed))
  FAILED=$((FAILED + missing))
  verb="sorted"
  [[ "$DRY_RUN" -eq 1 ]] && verb="checked"
  line="$verb $placed"
  [[ "$existing" -gt 0 ]] && line="$line ($existing already in the library)"
  [[ "$missing" -gt 0 ]] && line="$line, $missing failed to copy"
  finish "$status $line"
done <<< "$FOLDERS"

find "$STAGE" -type d -empty -delete 2>/dev/null || true
find "$LIB/.incoming" -type d -empty -delete 2>/dev/null || true

if [[ -s "$WORK/summary" ]]; then
  info ""
  if [[ "$DRY_RUN" -eq 1 ]]; then info "would sort into:"; else info "sorted into:"; fi
  sort "$WORK/summary" | uniq -c | awk '{ n = $1; $1 = ""; printf "  %6d  %s\n", n, substr($0, 2) }'
fi
info ""
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "practice run done: $SORTED file(s) checked, nothing sorted. Run without --dry-run to sort them."
else
  info "imported $SORTED new file(s); $TOTAL files on the phone"
fi

if [[ "$FAILED" -gt 0 ]]; then
  die "$FAILED item(s) failed. Keep the iPhone unlocked and re-run the same command; only what's missing is copied."
fi
[[ "$DRY_RUN" -eq 1 ]] && exit 0

if [[ -n "$RSYNC_TARGET" && "$DRY_RUN" -eq 0 ]]; then
  info "rsync -> $RSYNC_TARGET"
  rsync -avh --progress --exclude '.incoming/' "$LIB/" "$RSYNC_TARGET"
  info "done."
  exit 0
fi

info "photos are in: $LIB"
if [[ "$OPEN_AFTER" -eq 1 ]] && command -v open >/dev/null 2>&1; then
  open "$LIB"
fi
