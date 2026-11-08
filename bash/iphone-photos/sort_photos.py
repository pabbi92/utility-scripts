#!/usr/bin/env python3
"""Sort photos copied off an iPhone into the library.

  Screenshots/<year>/                 screenshots
  <year>/<country>/<state>/           photos and videos with GPS
  <year>/Unknown location/            everything else

Files are renamed to "<YYYY-MM-DD_HHMMSS>_<original name>". Edit sidecars (.AAE)
follow the photo or video with the same number.

Called by iphone-photos.sh once per DCIM folder; uses only the Python standard
library plus exiftool.
"""

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

PRIMARY_ORDER = ["HEIC", "HEIF", "JPG", "JPEG", "PNG", "DNG", "GIF", "TIF", "TIFF", "MOV", "MP4", "M4V"]
QUICKTIME = {"MOV", "MP4", "M4V"}
SIDECARS = {"AAE"}
UNKNOWN = "Unknown location"
MAX_PLACE_KM = 100
PREFIX_LEN = len("YYYY-MM-DD_HHMMSS_")


def ext_of(name):
    return os.path.splitext(name)[1][1:].upper()


def base_of(name):
    return os.path.splitext(name)[0].upper()


def clean(part):
    part = part.replace("/", "-").replace(":", "-").strip().strip(".")
    return part or "Unknown"


class Places:
    """Offline reverse geocoder over the GeoNames cities1000 dump."""

    def __init__(self, gdir):
        self.countries = {}
        with open(os.path.join(gdir, "countryInfo.txt"), encoding="utf-8") as f:
            for line in f:
                if line.startswith("#"):
                    continue
                cols = line.rstrip("\n").split("\t")
                if len(cols) > 4:
                    self.countries[cols[0]] = cols[4]

        self.admin1 = {}
        with open(os.path.join(gdir, "admin1CodesASCII.txt"), encoding="utf-8") as f:
            for line in f:
                cols = line.rstrip("\n").split("\t")
                if len(cols) > 2:
                    self.admin1[cols[0]] = cols[2]

        self.grid = {}
        with open(os.path.join(gdir, "cities1000.txt"), encoding="utf-8") as f:
            for line in f:
                cols = line.split("\t")
                lat, lon = float(cols[4]), float(cols[5])
                cell = (math.floor(lat), math.floor(lon))
                self.grid.setdefault(cell, []).append((lat, lon, cols[8], cols[10]))

        self.cache = {}

    def lookup(self, lat, lon):
        key = (round(lat, 2), round(lon, 2))
        if key not in self.cache:
            self.cache[key] = self._nearest(lat, lon)
        return self.cache[key]

    def _nearest(self, lat, lon):
        coslat = max(math.cos(math.radians(lat)), 0.05)
        rlat = math.ceil(MAX_PLACE_KM / 111.0)
        rlon = min(math.ceil(MAX_PLACE_KM / (111.0 * coslat)), 180)
        cy, cx = math.floor(lat), math.floor(lon)
        best, best_km = None, float("inf")
        for dy in range(-rlat, rlat + 1):
            for dx in range(-rlon, rlon + 1):
                cell = (cy + dy, (cx + dx + 180) % 360 - 180)
                for plat, plon, cc, a1 in self.grid.get(cell, ()):
                    dlon = (plon - lon + 540) % 360 - 180
                    km = 111.0 * math.hypot(plat - lat, dlon * coslat)
                    if km < best_km:
                        best, best_km = (cc, a1), km
        if best is None or best_km > MAX_PLACE_KM:
            return None
        cc, a1 = best
        country = self.countries.get(cc, cc)
        state = self.admin1.get("%s.%s" % (cc, a1)) or country
        return clean(country), clean(state)


def read_metadata(staging, names):
    if not names:
        return {}
    with tempfile.NamedTemporaryFile("w", suffix=".args", delete=False, encoding="utf-8") as args:
        for name in names:
            args.write(os.path.join(staging, name) + "\n")
    try:
        out = subprocess.run(
            ["exiftool", "-j", "-n", "-fast", "-charset", "filename=utf8",
             "-DateTimeOriginal", "-CreationDate", "-CreateDate", "-UserComment",
             "-Composite:GPSLatitude", "-Composite:GPSLongitude", "-@", args.name],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        ).stdout
    finally:
        os.unlink(args.name)
    meta = {}
    for item in json.loads(out.decode("utf-8") or "[]"):
        meta[os.path.basename(item.get("SourceFile", ""))] = item
    return meta


def parse_time(value):
    if not isinstance(value, str) or value.startswith("0000"):
        return None
    try:
        return datetime.strptime(value.strip()[:19], "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None


def capture_time(name, meta, path):
    for key in ("DateTimeOriginal", "CreationDate"):
        when = parse_time(meta.get(key))
        if when:
            return when
    when = parse_time(meta.get("CreateDate"))
    if when and ext_of(name) in QUICKTIME:
        # QuickTime CreateDate is stored in UTC.
        when = when.replace(tzinfo=timezone.utc).astimezone().replace(tzinfo=None)
    if when:
        return when
    return datetime.fromtimestamp(os.path.getmtime(path))


def destination(name, meta, path, places):
    when = capture_time(name, meta, path)
    if str(meta.get("UserComment", "")).strip().lower() == "screenshot":
        return "Screenshots/%d" % when.year, when
    lat, lon = meta.get("GPSLatitude"), meta.get("GPSLongitude")
    if isinstance(lat, (int, float)) and isinstance(lon, (int, float)) and (lat, lon) != (0, 0):
        place = places().lookup(lat, lon)
        if place:
            return "%d/%s/%s" % (when.year, place[0], place[1]), when
    return "%d/%s" % (when.year, UNKNOWN), when


def load_manifest(path, udid, folder):
    """Return (photo number -> library path of an imported photo/video,
    set of (name, size) already recorded) for one device folder."""
    known, recorded = {}, set()
    if not os.path.exists(path):
        return known, recorded
    with open(path, encoding="utf-8") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) == 5 and cols[0] == udid and cols[1] == folder:
                recorded.add((cols[2], cols[3]))
                if ext_of(cols[2]) not in SIDECARS:
                    known[base_of(cols[2])] = cols[4]
    return known, recorded


def place_file(src, library, reldir, fname, size, dry_run):
    """Return (library-relative path, True if an identical file was already there)."""
    destdir = os.path.join(library, reldir)
    stem, ext = os.path.splitext(fname)
    candidate, n = fname, 1
    while True:
        dest = os.path.join(destdir, candidate)
        if not os.path.exists(dest):
            break
        if os.path.getsize(dest) == size:
            if not dry_run:
                os.unlink(src)
            return os.path.join(reldir, candidate), True
        n += 1
        candidate = "%s_%d%s" % (stem, n, ext)
    if not dry_run:
        os.makedirs(destdir, exist_ok=True)
        os.rename(src, dest)
    return os.path.join(reldir, candidate), False


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--staging", required=True, help="folder holding the downloaded files")
    ap.add_argument("--files", required=True, help="TSV of <name> <size> to sort")
    ap.add_argument("--library", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--udid", required=True)
    ap.add_argument("--folder", required=True, help="DCIM folder name, e.g. 100APPLE")
    ap.add_argument("--geonames", required=True)
    ap.add_argument("--summary", required=True, help="file to append one destination folder per file to")
    ap.add_argument("--dry-run", action="store_true")
    opts = ap.parse_args()

    sizes = {}
    with open(opts.files, encoding="utf-8") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) == 2:
                sizes[cols[0]] = int(cols[1])

    groups = {}
    for name in sizes:
        groups.setdefault(base_of(name), []).append(name)

    primaries = {}
    for base, names in groups.items():
        media = [n for n in names if ext_of(n) not in SIDECARS]
        if media:
            rank = lambda n: PRIMARY_ORDER.index(ext_of(n)) if ext_of(n) in PRIMARY_ORDER else len(PRIMARY_ORDER)
            primaries[base] = min(media, key=rank)

    meta = read_metadata(opts.staging, [n for n in sizes if ext_of(n) not in SIDECARS])
    known, recorded = load_manifest(opts.manifest, opts.udid, opts.folder)

    loaded = []

    def places():
        if not loaded:
            loaded.append(Places(opts.geonames))
        return loaded[0]

    placed, existing = 0, 0
    with open(opts.manifest, "a", encoding="utf-8") as manifest, \
            open(opts.summary, "a", encoding="utf-8") as summary:
        for base in sorted(groups):
            primary = primaries.get(base)
            if primary:
                path = os.path.join(opts.staging, primary)
                reldir, when = destination(primary, meta.get(primary, {}), path, places)
                prefix = when.strftime("%Y-%m-%d_%H%M%S_")
            elif base in known:
                reldir = os.path.dirname(known[base])
                prefix = os.path.basename(known[base])[:PREFIX_LEN]
            else:
                path = os.path.join(opts.staging, groups[base][0])
                when = datetime.fromtimestamp(os.path.getmtime(path))
                reldir, prefix = "%d/%s" % (when.year, UNKNOWN), when.strftime("%Y-%m-%d_%H%M%S_")

            for name in sorted(groups[base]):
                src = os.path.join(opts.staging, name)
                rel, already = place_file(src, opts.library, reldir, prefix + name, sizes[name], opts.dry_run)
                if already:
                    existing += 1
                else:
                    summary.write(reldir + "\n")
                    placed += 1
                if not opts.dry_run and (name, str(sizes[name])) not in recorded:
                    manifest.write("\t".join([opts.udid, opts.folder, name, str(sizes[name]), rel]) + "\n")
                    manifest.flush()

    print(placed, existing)


if __name__ == "__main__":
    sys.exit(main())
