#!/usr/bin/env python3
"""Workshop collection helper for install_docker.sh.

Three jobs, one per subcommand:

    resolve <collection_id>          member publishedfileids, one per line
    stale   <content_dir> <id>...    subset that actually needs downloading
    stamp   <content_dir> <since> <id>...   record what we now have on disk
    mapname <content_dir> <id>       the map name the engine addresses

CS2 ships workshop maps as a single `<id>.vpk` per item, and the map name inside
it is NOT derivable from the directory name or from publish_data.txt - item
3071818846 has source_folder "kitchoon" but contains maps/de_rats_kitchoon.vpk.
So `mapname` reads the VPK directory tree, which is authoritative.

State lives next to the content on the persisted volume, so a pod restart does
not re-download 50 GB of maps that are already there.
"""

import json
import os
import struct
import sys
import urllib.parse
import urllib.request

APPID = 730
STATE_FILE = ".cs2_workshop_state.json"
API_COLLECTION = ("https://api.steampowered.com"
                  "/ISteamRemoteStorage/GetCollectionDetails/v1/")
API_DETAILS = ("https://api.steampowered.com"
               "/ISteamRemoteStorage/GetPublishedFileDetails/v1/")
TIMEOUT = 30


def post(url, fields):
    data = urllib.parse.urlencode(fields).encode("utf-8")
    req = urllib.request.Request(url, data=data)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read())


def state_path(content_dir):
    # One level up from content/730, i.e. steamapps/workshop/.
    return os.path.join(os.path.dirname(os.path.dirname(content_dir)),
                        STATE_FILE)


def load_state(content_dir):
    try:
        with open(state_path(content_dir)) as fh:
            return json.load(fh)
    except Exception:
        return {}


def vpk_path(content_dir, item_id):
    """The directory VPK for an item, or None if the item is not on disk.

    Small items are a single <id>.vpk. Large ones are split into numbered
    archives with the directory tree in <id>_dir.vpk - the numbered parts have
    no tree of their own, so the _dir file is the one to read.
    """
    base = os.path.join(content_dir, item_id)
    for candidate in ("%s.vpk" % item_id, "%s_dir.vpk" % item_id):
        path = os.path.join(base, candidate)
        if os.path.exists(path):
            return path
    return None


def remote_times(ids):
    """publishedfileid -> time_updated. Empty dict if Steam will not say."""
    fields = {"itemcount": len(ids)}
    for i, item_id in enumerate(ids):
        fields["publishedfileids[%d]" % i] = item_id
    try:
        body = post(API_DETAILS, fields)
        details = body["response"]["publishedfiledetails"]
    except Exception as exc:
        sys.stderr.write("workshop: cannot read published file details: %s\n"
                         % exc)
        return {}
    out = {}
    for d in details:
        item_id = str(d.get("publishedfileid", ""))
        updated = d.get("time_updated")
        if item_id and updated is not None:
            out[item_id] = int(updated)
    return out


def cmd_resolve(collection_id):
    try:
        body = post(API_COLLECTION, {
            "collectioncount": 1,
            "publishedfileids[0]": collection_id,
        })
        children = body["response"]["collectiondetails"][0].get("children", [])
    except Exception as exc:
        sys.stderr.write("workshop: cannot resolve collection %s: %s\n"
                         % (collection_id, exc))
        return 1
    for child in children:
        print(child["publishedfileid"])
    return 0


def cmd_stale(content_dir, ids):
    """Print the ids that need a download.

    missing vpk                         -> download
    recorded stamp differs from remote  -> download
    no stamp, remote newer than the vpk -> download (first run after upgrade)
    otherwise                           -> skip
    """
    state = load_state(content_dir)
    remote = remote_times(ids)
    for item_id in ids:
        path = vpk_path(content_dir, item_id)
        if path is None:
            print(item_id)
            continue
        if not remote:
            # Steam is unreachable; trust what is on disk rather than
            # re-downloading everything blind.
            continue
        updated = remote.get(item_id)
        if updated is None:
            continue
        stamped = state.get(item_id)
        if stamped is not None:
            if int(stamped) != updated:
                print(item_id)
            continue
        if updated > int(os.path.getmtime(path)):
            print(item_id)
    return 0


def cmd_stamp(content_dir, since, ids):
    """Record time_updated for items whose vpk is present and current.

    `since` is the epoch second the download started: an item whose vpk was
    written at or after it came from this run, so its stamp is trustworthy.
    Items that were never in the download set keep whatever they had.
    """
    state = load_state(content_dir)
    remote = remote_times(ids)
    if not remote:
        return 0
    for item_id in ids:
        path = vpk_path(content_dir, item_id)
        if path is None:
            continue
        if os.path.getmtime(path) < since:
            continue
        updated = remote.get(item_id)
        if updated is not None:
            state[item_id] = updated
    target = state_path(content_dir)
    tmp = target + ".tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(state, fh)
        os.replace(tmp, target)
    except Exception as exc:
        sys.stderr.write("workshop: cannot write %s: %s\n" % (target, exc))
        return 1
    return 0


def read_cstring(fh):
    out = bytearray()
    while True:
        char = fh.read(1)
        if not char or char == b"\x00":
            return out.decode("utf-8", "replace")
        out += char


def vpk_entries(path):
    """Yield (directory, name, ext) for every file in a VPK's directory tree."""
    with open(path, "rb") as fh:
        header = fh.read(12)
        if len(header) < 12:
            return
        signature, version, tree_size = struct.unpack("<III", header)
        if signature != 0x55AA1234:
            return
        if version == 2:
            fh.read(16)
        elif version != 1:
            return
        tree_end = fh.tell() + tree_size
        while fh.tell() < tree_end:
            ext = read_cstring(fh)
            if not ext:
                return
            while True:
                directory = read_cstring(fh)
                if not directory:
                    break
                while True:
                    name = read_cstring(fh)
                    if not name:
                        break
                    entry = fh.read(18)
                    if len(entry) < 18:
                        return
                    preload = struct.unpack("<H", entry[4:6])[0]
                    if preload:
                        fh.read(preload)
                    yield directory.strip(), name, ext


def cmd_mapname(content_dir, item_id):
    """The name the engine wants in workshop/<id>/<name>."""
    path = vpk_path(content_dir, item_id)
    if path is None:
        sys.stderr.write("workshop: no vpk on disk for item %s\n" % item_id)
        return 1
    try:
        entries = list(vpk_entries(path))
    except Exception as exc:
        sys.stderr.write("workshop: cannot read %s: %s\n" % (path, exc))
        return 1
    # CS2 packs the playable map as maps/<name>.vpk, older content as
    # maps/<name>.bsp. Anything deeper (maps/prefabs/...) is a component of the
    # map, not the map, so match the directory exactly.
    for want in ("vpk", "bsp"):
        for directory, name, ext in entries:
            if directory == "maps" and ext == want:
                print(name)
                return 0
    sys.stderr.write("workshop: no map entry in %s\n" % path)
    return 1


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd = sys.argv[1]
    args = sys.argv[2:]
    try:
        if cmd == "resolve" and len(args) == 1:
            return cmd_resolve(args[0])
        if cmd == "stale" and len(args) >= 2:
            return cmd_stale(args[0], args[1:])
        if cmd == "stamp" and len(args) >= 3:
            return cmd_stamp(args[0], int(args[1]), args[2:])
        if cmd == "mapname" and len(args) == 2:
            return cmd_mapname(args[0], args[1])
    except Exception as exc:
        sys.stderr.write("workshop: %s failed: %s\n" % (cmd, exc))
        return 1
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
