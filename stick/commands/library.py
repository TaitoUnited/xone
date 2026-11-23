#!/usr/bin/env python3
"""Keep Fix Xbox controllers in the Steam library.

It is a non-Steam game in shortcuts.vdf of the Steam account in use. An entry
that is there stays as it is. A missing one is added back, and each piece of
art that Steam's grid folder lacks is copied in from fix-art next to this
script. An entry in Steam's Hidden collection, which localconfig.vdf keeps for
non-Steam games, is taken out of it. Steam reads both files when it starts and
writes them from memory later, so a change made while Steam runs is lost:

  library         In Desktop Mode: closes Steam, then puts back what is
                  missing or hidden.
  library --fix   For Fix Xbox controllers, while Steam runs: when the entry
                  is missing or hidden, leaves restore-on-boot and exits
                  with 3.
  library --boot  Puts back what is missing or hidden, without closing Steam.
                  The user unit steambox-library.service runs it when the
                  machine starts, before Steam reads the files, if
                  restore-on-boot is there.

Each run that finds something to put back writes what it saw to library.log in
~/.local/share/steambox.
"""

import binascii
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

FIX = "Fix Xbox controllers"
HOME = Path.home()
HERE = Path(__file__).resolve().parent
STEAM = HOME / ".local/share/Steam"
STATE = HOME / ".local/share/steambox"
FLAG = STATE / "restore-on-boot"
KONSOLE = Path("/usr/bin/konsole")
WRAPPER = HOME / "fix-xbox-controllers.sh"
STAMP = time.strftime("%Y%m%d-%H%M%S")
FIX_ART = {"portrait.png": "{}p.png", "wide.png": "{}.png", "hero.png": "{}_hero.png",
           "logo.png": "{}_logo.png", "icon.png": "{}_icon.png"}


# Steam keeps the collections of non-Steam games on one line of localconfig.vdf,
# as JSON with its quotes escaped: "user-collections" "{\"hidden\":{...}}".
COLLECTIONS = re.compile(r'''^(\s*"user-collections"\s+")((?:[^"\\]|\\.)*)(")''', re.M)


class Stop(Exception):
    pass


def read_vdf(data):
    pos = 0

    def cstr():
        nonlocal pos
        end = data.index(b"\x00", pos)
        s = data[pos:end].decode("utf-8")
        pos = end + 1
        return s

    def node():
        nonlocal pos
        out = {}
        while True:
            t = data[pos]
            pos += 1
            if t == 0x08:
                return out
            key = cstr()
            if t == 0x00:
                out[key] = node()
            elif t == 0x01:
                out[key] = cstr()
            elif t == 0x02:
                out[key] = struct.unpack_from("<i", data, pos)[0]
                pos += 4
            else:
                raise Stop(f"unknown field type {t:#x} in shortcuts.vdf")

    return node()


def write_vdf(tree):
    out = bytearray()
    for key, val in tree.items():
        k = key.encode("utf-8") + b"\x00"
        if isinstance(val, dict):
            out += b"\x00" + k + write_vdf(val)
        elif isinstance(val, int):
            out += b"\x02" + k + struct.pack("<i", val)
        else:
            out += b"\x01" + k + str(val).encode("utf-8") + b"\x00"
    return bytes(out + b"\x08")


def field(entry, name, default=None):
    """Steam writes appname in lower case, these scripts AppName."""
    return next((v for k, v in entry.items() if k.lower() == name.lower()), default)


def shortcuts_in(vdf):
    if not vdf.is_file() or not vdf.stat().st_size:
        return []
    return list(field(read_vdf(vdf.read_bytes()), "shortcuts", {}).values())


def steam_running():
    return subprocess.run(["pgrep", "-x", "steam"],
                          stdout=subprocess.DEVNULL).returncode == 0


def close_steam():
    if not steam_running():
        return
    print("Closing Steam...")
    subprocess.run(["steam", "-shutdown"], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
    for _ in range(60):
        if not steam_running():
            return
        time.sleep(1)
    raise Stop("Steam is still running. Quit it from its tray icon and run this again.")


def recent_account():
    login = STEAM / "config/loginusers.vdf"
    if login.exists():
        for m in re.finditer(r'"(\d{17})"\s*\{([^}]*)\}', login.read_text(errors="replace")):
            if re.search(r'"MostRecent"\s*"1"', m.group(2)):
                return str(int(m.group(1)) - 76561197960265728)
    return None


def user_dir():
    users = [d for d in (STEAM / "userdata").glob("*")
             if d.is_dir() and d.name.isdigit() and d.name != "0"]
    if not users:
        raise Stop(f"no Steam account folder in {STEAM / 'userdata'}")
    recent = recent_account()
    for d in users:
        if len(users) > 1 and d.name == recent:
            return d
    return max(users, key=lambda d: d.stat().st_mtime)


def shortcut(name, exe, start_dir, options):
    appid = binascii.crc32((exe + name).encode("utf-8")) | 0x80000000
    return {
        "appid": appid - (1 << 32),
        "AppName": name,
        "Exe": exe,
        "StartDir": start_dir,
        "icon": "",
        "ShortcutPath": "",
        "LaunchOptions": options,
        "IsHidden": 0,
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "OpenVR": 0,
        "Devkit": 0,
        "DevkitGameID": "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime": 0,
        "FlatpakAppID": "",
        "tags": {},
    }


def fix_entry(grid):
    for path in (KONSOLE, WRAPPER):
        if not path.exists():
            return None, f"no {path}"
    entry = shortcut(FIX, f'"{KONSOLE}"', f'"{HOME}/"', f'-e "{WRAPPER}"')
    entry["icon"] = str(grid / FIX_ART["icon.png"].format(entry["appid"] & 0xFFFFFFFF))
    return entry, None


def plan(user):
    """Return shortcuts.vdf, its entries, and per wanted entry what to do:
    its name, the entry to add or None, the reason none can be added, and
    the art to copy as (source, target) pairs."""
    vdf = user / "config/shortcuts.vdf"
    grid = vdf.with_name("grid")
    have = shortcuts_in(vdf)
    todo = []
    for name, make, art, files in ((FIX, lambda: fix_entry(grid), "fix-art", FIX_ART),):
        found = next((e for e in have if field(e, "appname") == name), None)
        add, why = (None, None) if found else make()
        appid = field(found or add or {}, "appid", 0)
        copies = []
        if isinstance(appid, int) and appid:
            copies = [(HERE / art / src, grid / target.format(appid & 0xFFFFFFFF))
                      for src, target in files.items()]
            copies = [(s, t) for s, t in copies if s.is_file() and not t.exists()]
        todo.append((name, add, why, copies))
    return vdf, have, todo


def apply(vdf, have, todo):
    for _, _, _, copies in todo:
        for src, target in copies:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, target)
    adds = [add for _, add, _, _ in todo if add]
    if not adds:
        return
    vdf.parent.mkdir(parents=True, exist_ok=True)
    if vdf.exists() and vdf.stat().st_size:
        shutil.copy2(vdf, vdf.with_name(f"shortcuts.vdf.bak-{STAMP}"))
    new = vdf.with_name("shortcuts.vdf.new")
    new.write_bytes(write_vdf({"shortcuts": {str(i): e for i, e in enumerate(have + adds)}}))
    os.replace(new, vdf)


def collections(match):
    try:
        data = json.loads(re.sub(r"\\(.)", r"\1", match.group(2)))
    except ValueError:
        return None
    hidden = data.get("hidden") if isinstance(data, dict) else None
    return data if isinstance(hidden, dict) and isinstance(hidden.get("added"), list) else None


def hidden(vdf, have):
    """Return localconfig.vdf and the wanted entries in its Hidden collection,
    as name: appid."""
    local = vdf.with_name("localconfig.vdf")
    ids = set()
    if local.is_file():
        for m in COLLECTIONS.finditer(local.read_bytes().decode("utf-8", "surrogateescape")):
            ids.update((collections(m) or {"hidden": {"added": []}})["hidden"]["added"])
    found = {}
    for e in have:
        appid = field(e, "appid", 0)
        if field(e, "appname") == FIX and isinstance(appid, int) \
                and appid & 0xFFFFFFFF in ids:
            found[field(e, "appname")] = appid & 0xFFFFFFFF
    return local, found


def unhide(local, ids):
    if not ids:
        return

    def shown(match):
        data = collections(match)
        if not data or not ids & set(data["hidden"]["added"]):
            return match.group(0)
        data["hidden"]["added"] = [i for i in data["hidden"]["added"] if i not in ids]
        text = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
        return match.group(1) + text.replace("\\", "\\\\").replace('"', '\\"') + match.group(3)

    old = local.read_bytes().decode("utf-8", "surrogateescape")
    new = COLLECTIONS.sub(shown, old)
    if new == old:
        return
    shutil.copy2(local, local.with_name(f"localconfig.vdf.bak-{STAMP}"))
    tmp = local.with_name("localconfig.vdf.new")
    tmp.write_bytes(new.encode("utf-8", "surrogateescape"))
    shutil.copymode(local, tmp)
    os.replace(tmp, local)


def outcome(todo, hid, done):
    lines = []
    for name, add, why, copies in todo:
        art = f", {len(copies)} art files copied" if copies and done else ""
        if add:
            state = "was missing, added back" if done else "missing from the library"
        elif why:
            state = f"missing and cannot be put back: {why}"
        elif name in hid:
            state = "was hidden, shown again" if done else "hidden in the library"
        else:
            state = "in the library"
        lines.append(f"{name}: {state}{art}.")
    return lines


def describe():
    """What a later reader needs to see why an entry went missing."""
    when = lambda p: time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(p.stat().st_mtime))
    lines = [f"Steam running: {steam_running()}; account in use: {recent_account()}"]
    for f in sorted((STEAM / "userdata").glob("*/config/shortcuts.vdf*")):
        lines.append(f"{f}: {f.stat().st_size} bytes, changed {when(f)}")
        try:
            for e in shortcuts_in(f):
                lines.append("  {!r} appid {} played {} hidden {} exe {} options {}".format(
                    field(e, "appname"), field(e, "appid", 0) & 0xFFFFFFFF,
                    field(e, "LastPlayTime"), field(e, "IsHidden"), field(e, "Exe"),
                    field(e, "LaunchOptions")))
        except Exception as err:
            lines.append(f"  unreadable: {err!r}")
    for f in sorted((STEAM / "userdata").glob("*/config/localconfig.vdf")):
        for m in COLLECTIONS.finditer(f.read_bytes().decode("utf-8", "surrogateescape")):
            lines.append(f"{f}, changed {when(f)}: collections {m.group(2)[:600]}")
    for f in sorted((STEAM / "logs").glob("*.txt")):
        hits = [l.rstrip() for l in f.read_text(errors="replace").splitlines()
                if re.search(r"shortcut|non-steam", l, re.I)
                and not re.search(r"token|password|secret|auth|cookie", l, re.I)]
        if hits:
            lines.append(f"{f}, changed {when(f)}, last {min(len(hits), 40)} matching lines:")
            lines += [f"  {l[:300]}" for l in hits[-40:]]
    return lines


def record(title, lines):
    text = "\n".join([f"===== {title}, {STAMP} ====="] + lines) + "\n\n"
    target = STATE / "library.log"
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a") as out:
            out.write(text)
    except OSError as err:
        print(f"Could not write {target}: {err}")


def main():
    mode = next((a for a in sys.argv[1:] if a in ("--fix", "--boot")), None)
    if mode == "--boot":
        FLAG.unlink(missing_ok=True)
    vdf, have, todo = plan(user_dir())
    local, hid = hidden(vdf, have)
    missing = bool(hid) or any(add for _, add, _, _ in todo)
    work = missing or any(copies for _, _, _, copies in todo)
    seen = describe() if work or not mode else []

    if mode == "--fix":
        # Art can go in while Steam runs; the rest waits for the next start.
        apply(vdf, have, [(name, None, why, copies) for name, _, why, copies in todo])
        print("\n".join(outcome(todo, hid, False)))
        if missing:
            STATE.mkdir(parents=True, exist_ok=True)
            FLAG.touch()
            record("Fix Xbox controllers found entries to change",
                   seen + outcome(todo, hid, False))
            sys.exit(3)
        return

    if work and not mode:
        close_steam()
        # Steam may have written its files as it closed.
        vdf, have, todo = plan(user_dir())
        local, hid = hidden(vdf, have)
    apply(vdf, have, todo)
    unhide(local, set(hid.values()))
    result = outcome(todo, hid, True)
    print("\n".join(result))
    if work or not mode:
        record("library --boot" if mode else "library", seen + result)
    if work and not mode:
        print("Return to Gaming Mode; it is under Non-Steam in the library.")


if __name__ == "__main__":
    try:
        main()
    except Stop as err:
        print(f"Stopped: {err}", file=sys.stderr)
        sys.exit(1)
