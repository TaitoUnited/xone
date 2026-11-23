#!/usr/bin/env python3
"""Find out why Xbox pads drop off the Xbox Wireless Adapter.

padlog.py watch runs all the time as steambox-padlog.service, which setup.sh
installs. It notes each pad that connects or drops, with its battery level
and how long it went without input, and the adapter, its pairing, Wi-Fi and
sleep, in ~/.local/share/steambox/padlog/.

padlog.py report, which Fix Xbox controllers runs at each start and padlog
runs in Konsole, lines those notes up with the kernel log and Steam's
controller log, says why each pad dropped and saves the report to
~/.local/share/steambox and steambox-info/ on the SHARE stick. xone names the
cause only while its debug lines are on, which run/xone-debug-lines.sh does.
"""

import glob
import json
import os
import re
import select
import shutil
import struct
import subprocess
import sys
import time

LIB = os.path.expanduser("~/.local/share/steambox")
LOGS = os.path.join(LIB, "padlog")
KEEP_DAYS = 30
ADAPTER_IDS = {"02e6", "02fe", "02f9", "091e"}
# The pads this was tested with report these, as Steam's controller log shows.
MODELS = {"02d1": "Model 1537", "02dd": "Model 1537", "02ea": "Model 1708"}
INPUT_EVENT = struct.Struct("llHHi")
EV_KEY, EV_ABS = 1, 3
# How far an axis has to move to count as input, so stick drift does not.
TRIGGERS, HATS = (2, 5), (16, 17)

KERNEL_RE = re.compile(
    r"xone|gip\d|usb \d+-[\d.]+:|usb usb\d|xhci|045e|"
    r"PM: suspend (entry|exit)|PM: hibernation: (entry|exit)")
NOISE_RE = re.compile(
    r"deprecated workqueue|module verification failed|out-of-tree module")
ERROR_RE = re.compile(
    r"xone.*(failed|error|timed out|already initialized)|"
    r"(xone|usb \d).*-(71|108|110|121)\b|unable to enumerate|"
    r"device descriptor read|not accepting address|over-current")
# Lines that xone prints only while its debug lines are on.
DEBUG_ONLY_RE = re.compile(r"xone_dongle_(add|remove)_client: wcid=|"
                           r"gip_\w+: (un)?registered|pairing_handler: enabled")
CHUNK_RE = re.compile(r"gip_init_chunk_buffer: already initialized")
SLOT_RE = re.compile(r"xone_dongle_(add_client|remove_client|handle_loss): wcid=(\d+)")
STEAM_DROP = "Controller device closed after hid_read failure"
STEAM_RE = re.compile(
    r"opened for index|closed|[Rr]emov|[Dd]isconnect|Product:|XInput slot")
STEAM_LOGS = ["~/.local/share/Steam/logs/controller.previous.txt",
              "~/.local/share/Steam/logs/controller.txt"]


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def output(cmd, timeout=20):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def stamp(t, seconds=True):
    return time.strftime("%a %d.%m %H:%M:%S" if seconds else "%a %d.%m %H:%M",
                         time.localtime(t))


def span(seconds):
    if seconds is None:
        return "unknown"
    seconds = int(seconds)
    if seconds < 120:
        return f"{seconds} s"
    if seconds < 7200:
        return f"{seconds // 60} min"
    return f"{seconds // 3600} h {seconds % 3600 // 60} min"


# --- What the machine shows now

def adapter_state():
    for d in sorted(glob.glob("/sys/bus/usb/devices/*")):
        if (read(f"{d}/idVendor") != "045e"
                or read(f"{d}/idProduct") not in ADAPTER_IDS):
            continue
        port = os.path.basename(d)
        iface = f"{d}/{port}:1.0"
        try:
            driver = os.path.basename(os.readlink(f"{iface}/driver"))
        except OSError:
            driver = ""
        m = re.search(r"Active clients: (\d+)", read(f"{iface}/active_clients"))
        return {"port": port, "devnum": read(f"{d}/devnum"),
                "product": read(f"{d}/idProduct"), "driver": driver,
                "pairing": read(f"{iface}/pairing"),
                "clients": int(m.group(1)) if m else None,
                "power": read(f"{d}/power/runtime_status")}
    return None


def pads_now():
    pads = {}
    for d in glob.glob("/sys/class/input/input*"):
        phys = read(f"{d}/phys")
        if not phys.startswith("gip"):
            continue
        name = os.path.basename(d)
        events = sorted(glob.glob(f"{d}/event*"))
        gip = phys.split("/")[0]
        pads[name] = {"input": name, "gip": gip, "name": read(f"{d}/name"),
                      "serial": read(f"{d}/uniq"),
                      "product": read(f"{d}/id/product"),
                      "event": os.path.basename(events[0]) if events else ""}
    return pads


def battery(gip):
    d = f"/sys/class/power_supply/{gip}"
    level = read(f"{d}/capacity_level")
    return f"{level}, {read(f'{d}/status')}" if level else ""


def xone_debug():
    """How many of xone's debug lines are on, as 'on 40 of 60'."""
    try:
        with open("/proc/dynamic_debug/control") as f:
            sites = [line for line in f
                     if "[xone_dongle]" in line or "[xone_gip]" in line]
    except OSError:
        return "unreadable"
    if not sites:
        return "none"
    on = sum(1 for line in sites
             if "p" in (re.search(r" =(\S*)", line) or [None, ""])[1])
    return f"on {on} of {len(sites)}"


def wifi():
    for iface in re.findall(r"Interface (\S+)", output(["iw", "dev"])):
        link = output(["iw", "dev", iface, "link"])
        freq = re.search(r"freq: ([\d.]+)", link)
        if not freq:
            continue
        mhz = int(float(freq.group(1)))
        if mhz == 2484:
            chan = 14
        elif mhz < 3000:
            chan = (mhz - 2407) // 5
        elif mhz < 5950:
            chan = (mhz - 5000) // 5
        else:
            chan = (mhz - 5950) // 5
        signal = re.search(r"signal: (-?\d+)", link)
        return {"iface": iface, "mhz": mhz, "channel": chan,
                "signal": int(signal.group(1)) if signal else None}
    return None


def asleep_total():
    # CLOCK_BOOTTIME counts time asleep and CLOCK_MONOTONIC does not.
    return time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic()


# --- watch

def note(ev, **fields):
    t = time.time()
    path = os.path.join(LOGS, f"events-{time.strftime('%Y%m%d', time.localtime(t))}.log")
    with open(path, "a") as f:
        f.write(json.dumps({"t": round(t, 3), "ev": ev, **fields}) + "\n")


def prune():
    cutoff = time.strftime("%Y%m%d", time.localtime(time.time() - KEEP_DAYS * 86400))
    for path in glob.glob(os.path.join(LOGS, "events-*.log")):
        if os.path.basename(path)[7:15] < cutoff:
            os.remove(path)


class Pad:
    def __init__(self, info, already):
        self.info = info
        self.since = None if already else time.time()
        self.active = None
        self.axes = {}
        self.battery = battery(info["gip"])
        self.fd = None
        if info["event"]:
            try:
                self.fd = os.open(f"/dev/input/{info['event']}",
                                  os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                pass

    def read_input(self):
        try:
            data = os.read(self.fd, 4096)
        except BlockingIOError:
            return
        except OSError:
            self.close()
            return
        if not data:
            self.close()
            return
        size = INPUT_EVENT.size
        for off in range(0, len(data) - len(data) % size, size):
            _, _, kind, code, value = INPUT_EVENT.unpack_from(data, off)
            if kind == EV_KEY and value == 1:
                self.active = time.time()
            elif kind == EV_ABS:
                limit = 200 if code in TRIGGERS else 1 if code in HATS else 6000
                last = self.axes.setdefault(code, value)
                if abs(value - last) >= limit:
                    self.axes[code] = value
                    self.active = time.time()

    def update(self, info):
        if info["serial"] and not self.info["serial"]:
            self.info["serial"] = info["serial"]
            note("serial", input=info["input"], serial=info["serial"])
        level = battery(info["gip"])
        if level != self.battery:
            note("battery", input=info["input"], serial=self.info["serial"],
                 level=level, was=self.battery)
            self.battery = level

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class Watch:
    def __init__(self, debug):
        self.debug = debug
        self.next_debug = 0
        self.adapter = None
        self.first = True
        self.pads = {}
        self.asleep = asleep_total()
        self.next_wifi = 0
        self.wifi = None

    def scan(self):
        gap = asleep_total() - self.asleep
        if gap > 2:
            note("slept", seconds=round(gap))
            self.asleep += gap

        a, was = adapter_state(), self.adapter
        if self.first or any((a or {}).get(k) != (was or {}).get(k)
                             for k in ("port", "devnum", "driver")):
            note("adapter", present=a is not None, **(a or {}))
        elif a:
            for key in ("pairing", "clients", "power"):
                if a[key] != was[key]:
                    note(key, value=a[key], was=was[key])
        self.adapter = a

        now = pads_now()
        for name, pad in list(self.pads.items()):
            if name in now:
                pad.update(now[name])
                continue
            t = time.time()
            note("pad_off", **pad.info,
                 up=None if pad.since is None else round(t - pad.since),
                 idle=None if pad.active is None else round(t - pad.active),
                 battery=pad.battery, left=len(now),
                 adapter=a is not None, clients=(a or {}).get("clients"))
            pad.close()
            del self.pads[name]
        for name, info in now.items():
            if name not in self.pads:
                pad = self.pads[name] = Pad(info, already=self.first)
                note("pad_on", **info, battery=pad.battery, already=self.first,
                     reading=pad.fd is not None, count=len(now))
        self.first = False

        if time.monotonic() >= self.next_wifi:
            w, last = wifi(), self.wifi
            if (w is None) != (last is None) or w and (
                    w["mhz"] != last["mhz"]
                    or abs((w["signal"] or 0) - (last["signal"] or 0)) >= 10):
                note("wifi", **(w or {"connected": False}))
                self.wifi = w
            self.next_wifi = time.monotonic() + 600

        if time.monotonic() >= self.next_debug:
            debug = xone_debug()
            if debug != self.debug:
                note("debug", value=debug, was=self.debug)
                self.debug = debug
            self.next_debug = time.monotonic() + 60

    def read_input(self, until):
        while True:
            left = until - time.monotonic()
            if left <= 0:
                return
            fds = {p.fd: p for p in self.pads.values() if p.fd is not None}
            ready, _, _ = select.select(list(fds), [], [], left)
            for fd in ready:
                fds[fd].read_input()


def watch():
    os.makedirs(LOGS, exist_ok=True)
    prune()
    debug = xone_debug()
    note("start", kernel=os.uname().release,
         xone=output(["modinfo", "-F", "version", "xone_dongle"]).strip(),
         debug=debug, python=sys.version.split()[0])
    w = Watch(debug)
    day = time.strftime("%Y%m%d")
    while True:
        tick = time.monotonic()
        try:
            w.scan()
        except Exception as err:
            # A device that goes away mid-scan must not stop the logger.
            note("error", error=repr(err))
        if time.strftime("%Y%m%d") != day:
            day = time.strftime("%Y%m%d")
            prune()
        w.read_input(tick + 1)


# --- report

def load_events(since):
    events = []
    for path in sorted(glob.glob(os.path.join(LOGS, "events-*.log"))):
        with open(path) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("t", 0) >= since:
                    events.append(e)
    return events


def kernel_lines(since):
    lines = []
    text = output(["journalctl", "_TRANSPORT=kernel", "--since",
                   f"@{int(since)}", "-o", "json", "--output-fields=MESSAGE",
                   "--no-pager", "-q"], timeout=120)
    for row in text.splitlines():
        try:
            e = json.loads(row)
        except ValueError:
            continue
        msg = e.get("MESSAGE", "")
        if isinstance(msg, list):
            msg = bytes(b for b in msg if isinstance(b, int)).decode("utf-8", "replace")
        if KERNEL_RE.search(msg) and not NOISE_RE.search(msg):
            lines.append((int(e["__REALTIME_TIMESTAMP"]) / 1e6, msg))
    return lines


def steam_lines(since):
    lines = []
    for path in STEAM_LOGS:
        try:
            with open(os.path.expanduser(path), errors="replace") as f:
                for line in f:
                    m = re.match(r"\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] (.*)", line)
                    if not m or not STEAM_RE.search(m.group(2)):
                        continue
                    t = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
                    if t >= since:
                        lines.append((t, m.group(2).strip()))
        except OSError:
            pass
    return lines


def pad_keys(events):
    """A key per pad: its serial, which can arrive after it connected."""
    serials = {e["input"]: e["serial"] for e in events
               if e.get("input") and e.get("serial")}
    return lambda e: serials.get(e.get("input", "")) or e.get("input", "")


def pad_names(events, key_of):
    names = {}
    for e in events:
        if e["ev"] != "pad_on":
            continue
        key = key_of(e)
        if key not in names:
            model = MODELS.get(e.get("product", ""), f"045e:{e.get('product', '?')}")
            tail = f", serial ending {key[-4:]}" if key != e["input"] else ""
            names[key] = f"pad {chr(ord('A') + len(names) % 26)} ({model}{tail})"
    return names


def debug_on(value):
    return bool(value) and value.startswith("on ") and not value.startswith("on 0 ")


def debug_at(t, events):
    """Whether xone's debug lines were on at t, as the logger last read them."""
    value = None
    for e in events:
        if e["t"] > t:
            break
        if e["ev"] == "start":
            value = e.get("debug")
        elif e["ev"] == "debug":
            value = e.get("value")
    return debug_on(value)


def cause_of(drop, events, klines):
    t = drop["t"]
    near = [m for kt, m in klines if t - 8 <= kt <= t + 2]
    adapter = drop["gip"].split(".")[0]
    for e in events:
        if e["ev"] == "slept" and t - 3 <= e["t"] <= t + 3:
            return "sleep", f"the Steam Machine slept {span(e['seconds'])}"
    if not drop.get("adapter") or any(
            e["ev"] == "adapter" and t - 3 <= e["t"] <= t + 3 for e in events):
        return "adapter", "the adapter dropped off USB, which drops every pad"
    if any(t <= kt <= t + 60 and "PM: suspend entry" in m for kt, m in klines):
        return "sleep", "the Steam Machine was going to sleep"
    up = drop.get("up")
    if (up is not None and debug_at(t - up, events) and debug_at(t, events)
            and not any(t - up - 5 <= kt <= t
                        and f"{adapter}.0: gip_auth_complete_handshake" in m
                        for kt, m in klines)):
        return "handshake", ("the pad's handshake with the adapter never finished,"
                             " as in xone issue 210")
    if any(f"{adapter}: gip_handle_pkt_status: disconnected" in m for m in near):
        return "off", "the pad switched off"
    if any("xone_dongle_handle_loss" in m for m in near):
        return "lost", "the adapter lost the pad's signal"
    if any("xone_dongle_remove_client" in m for m in near):
        return "left", "the pad ended the connection without saying why"
    if not debug_at(t, events):
        return "unknown", "unknown, as xone's debug lines were off then"
    return "unknown", "unknown"


def report(days):
    since = time.time() - days * 86400
    events = load_events(since)
    klines = kernel_lines(since)
    slines = steam_lines(since)
    key_of = pad_keys(events)
    names = pad_names(events, key_of)
    starts = [e for e in events if e["ev"] == "start"]
    service = output(["systemctl", "--user", "is-active",
                      "steambox-padlog.service"]).strip() or "unknown"
    debug = xone_debug()

    head = [f"Xbox pad drops, {stamp(time.time(), False)}, from the last {days} days"]
    if starts:
        head.append(f"Pad logger: {service}, started {stamp(starts[0]['t'], False)}"
                    + (f" and {len(starts) - 1} times after" if len(starts) > 1 else ""))
    else:
        head.append(f"Pad logger: {service}, with no notes from these days.")
    if debug_on(debug):
        head.append(f"xone's debug lines: {debug}, so a drop gets its cause.")
    else:
        head.append(f"xone's debug lines: off or unknown ({debug}), so a drop's"
                    " cause can stay unknown.")

    drops = []
    for e in events:
        if e["ev"] != "pad_off":
            continue
        kind, why = cause_of(e, events, klines)
        back = next((o["t"] - e["t"] for o in events
                     if o["ev"] == "pad_on" and o["t"] > e["t"]
                     and key_of(o) == key_of(e)), None)
        drops.append((e, kind, why, back))

    lines = []
    if drops:
        lines.append(f"{len(drops)} drop{'s' if len(drops) > 1 else ''}:")
        for e, kind, why, back in drops:
            name = names.get(key_of(e), f"pad on {e['gip']}")
            facts = [f"idle {span(e.get('idle'))}" if e.get("idle") is not None
                     else "idle unknown",
                     f"battery {e.get('battery') or 'unknown'}",
                     f"connected {span(e.get('up'))}" if e.get("up") is not None
                     else "connected since before the logger",
                     f"{e.get('left', 0)} other pad(s) stayed",
                     f"back after {span(back)}" if back is not None else "not back"]
            lines.append(f"  {stamp(e['t'])}  {name}: {why}")
            lines.append(f"      {', '.join(facts)}")
        counts = {}
        for _, kind, why, _ in drops:
            counts[why] = counts.get(why, 0) + 1
        lines.append("Causes: " + "; ".join(f"{why} {n}" for why, n in
                                             sorted(counts.items(), key=lambda x: -x[1])))
    else:
        lines.append("No pad dropped in these days." if starts else
                     "No pad drops noted.")

    # Steam's own log reaches back before the logger started.
    steam_drops = quick = 0
    opened = None
    for t, m in slines:
        if "opened for index" in m:
            opened = t
        elif STEAM_DROP in m:
            steam_drops += 1
            if opened is not None and t - opened <= 15:
                quick += 1
    if steam_drops:
        lines.append(f"Steam lost a pad {steam_drops} times in these days, {quick} of"
                     " them within 15 s of the pad connecting.")

    notes = []
    for e, _, _, back in drops:
        if back is not None and back < 5:
            notes.append(f"{stamp(e['t'])}: a pad came back within {span(back)} of dropping.")
    for e in events:
        if e["ev"] == "pad_on" and not e.get("already"):
            off = next((o for o in events if o["ev"] == "pad_off"
                        and o["input"] == e["input"] and o["t"] >= e["t"]), None)
            if off and off["t"] - e["t"] <= 5:
                notes.append(f"{stamp(e['t'])}: a pad connected and dropped again"
                             f" {span(off['t'] - e['t'])} later, as in xone issue 219.")
    pad_ons = [e["t"] for e in events if e["ev"] == "pad_on"]
    for e in events:
        if (e["ev"] == "clients" and (e["value"] or 0) > (e["was"] or 0)
                and not any(e["t"] - 3 <= t <= e["t"] + 20 for t in pad_ons)):
            notes.append(f"{stamp(e['t'])}: a pad joined the adapter but got no input"
                         " device in 20 s, as in xone issues 195 and 219.")
    chunk = [kt for kt, m in klines if CHUNK_RE.search(m)]
    if chunk:
        notes.append(f"xone printed 'gip_init_chunk_buffer: already initialized'"
                     f" {len(chunk)} times, the sign of xone issue 219, the last at"
                     f" {stamp(chunk[-1])}.")
    held, ghosts = set(), []
    for kt, m in klines:
        if "xone_mt76_init_radio" in m:
            held.clear()
        slot = SLOT_RE.search(m)
        if not slot:
            continue
        kind, wcid = slot.groups()
        if kind == "add_client":
            held.add(wcid)
        elif kind == "remove_client":
            held.discard(wcid)
        elif wcid not in held:
            ghosts.append((kt, wcid))
    if len(ghosts) >= 20:
        first, last = ghosts[0][0], ghosts[-1][0]
        off_usb = sum(1 for kt, m in klines
                      if first <= kt <= last + 10 and "USB disconnect" in m)
        notes.append(f"The adapter reported a lost pad in a slot no pad held"
                     f" {len(ghosts)} times, from {stamp(first)} to {stamp(last)}"
                     f" (slots {', '.join(sorted({w for _, w in ghosts}, key=int))}),"
                     f" so its state no longer matched xone's; it dropped off USB"
                     f" {off_usb} times in that span.")
    freed = sum(1 for _, m in klines if "freeing empty wcid" in m)
    stale = sum(1 for _, m in klines if "replacing stale wcid" in m)
    fixed = [m for _, m in klines if "set by the channel option" in m]
    if freed or stale or fixed:
        notes.append(f"The Steam Machine patch freed {freed} adapter slots that xone held"
                     f" no pad in and replaced {stale} dead ones"
                     + (f"; {fixed[-1].split(': ', 2)[-1]}." if fixed else "."))
    errors = [(kt, m) for kt, m in klines
              if ERROR_RE.search(m) and not CHUNK_RE.search(m)]
    if errors:
        notes.append(f"{len(errors)} adapter or USB error lines, the last at"
                     f" {stamp(errors[-1][0])}: {errors[-1][1][:100]}")
    watched = [e for e, _, _, _ in drops if debug_at(e["t"], events)]
    if watched and not any(DEBUG_ONLY_RE.search(m) for kt, m in klines
                           if any(abs(kt - e["t"]) <= 10 for e in watched)):
        notes.append("xone's debug lines were on during a drop, but none of them"
                     " reached the journal.")
    if drops and not debug_on(debug):
        notes.append("run/xone-debug-lines.sh on the stick turns xone's debug lines on.")
    if notes:
        lines.append("")
        lines.append("Also:")
        lines.extend(f"  {n}" for n in notes)

    wifis = [e for e in events if e["ev"] == "wifi" and e.get("mhz")]
    tail = [f"Wi-Fi now: {wifis[-1]['iface']} on channel {wifis[-1]['channel']}"
            f" ({wifis[-1]['mhz']} MHz), signal {wifis[-1]['signal']} dBm"] if wifis else []
    chans = [m for _, m in klines if "xone_mt76_init_channels: channel=" in m or
             "channel switch" in m]
    if chans:
        tail.append(f"Adapter channel, last set: {chans[-1][-60:]}")

    timeline = []
    for e in events:
        fields = {k: v for k, v in e.items() if k not in ("t", "ev")}
        name = names.get(key_of(e), "") if e.get("input") else ""
        timeline.append((e["t"], f"PAD   {e['ev']} {name} {json.dumps(fields)}"))
    timeline += [(t, f"KERN  {m}") for t, m in klines]
    timeline += [(t, f"STEAM {m}") for t, m in slines]
    timeline.sort(key=lambda x: x[0])

    summary = head + [""] + lines + ([""] + tail if tail else [])
    full = summary + ["", "--- Timeline: the pad logger (PAD), the kernel (KERN)"
                      " and Steam's controller log (STEAM)"]
    full += [f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(t))}"
             f".{int(t % 1 * 1000):03d} {line}" for t, line in timeline]
    full += ["", "--- lsusb -t", output(["lsusb", "-t"]).rstrip()]

    name = f"padlog-{time.strftime('%Y%m%d-%H%M%S')}.txt"
    os.makedirs(LIB, exist_ok=True)
    path = os.path.join(LIB, name)
    with open(path, "w") as f:
        f.write("\n".join(full) + "\n")
    print("\n".join(summary))
    print()
    print(save_to_stick(path, name))


def save_to_stick(path, name):
    label = "/dev/disk/by-label/SHARE"
    saved = f"Saved the report as {path}"
    if not os.path.exists(label):
        return saved
    dev = os.path.realpath(label)

    def mountpoint():
        return next((line for line in output(["lsblk", "-no", "MOUNTPOINT", dev]).splitlines()
                     if line.strip()), "")

    target = mountpoint()
    mounted_here = False
    if not target and subprocess.run(["udisksctl", "mount", "-b", dev],
                                     capture_output=True).returncode == 0:
        target, mounted_here = mountpoint(), True
    try:
        if target:
            info = os.path.join(target, "steambox-info")
            os.makedirs(os.path.join(info, "padlog"), exist_ok=True)
            shutil.copyfile(path, os.path.join(info, name))
            for log in glob.glob(os.path.join(LOGS, "events-*.log")):
                shutil.copyfile(log, os.path.join(info, "padlog", os.path.basename(log)))
            saved = f"Saved the report on the stick too, as steambox-info/{name}"
    except OSError as err:
        saved += f" (the stick: {err.strerror})"
    os.sync()
    if mounted_here:
        subprocess.run(["udisksctl", "unmount", "-b", dev], capture_output=True)
    return saved


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["watch"]:
        watch()
    else:
        days = args[1] if args[:1] == ["report"] and len(args) > 1 else "7"
        report(int(days) if days.isdigit() else 7)
