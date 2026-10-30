#!/usr/bin/env python3
"""
Per-key keyboard chatter filter (debouncer) for Linux.

Linux counterpart of chatter-filter.ps1. It grabs the chattering keyboard at the
kernel (evdev) level, so nothing else sees its raw input, and re-emits it through
a virtual keyboard (uinput) with chatter removed. Works on X11, Wayland and the
text console alike.

When a key is pressed again less than --threshold ms after it was released, that
press is treated as switch chatter and dropped together with its release. Other
keys are never affected. Unlike the Windows version, only the chosen keyboard is
filtered (by USB vendor/product ID, default 36ae:fe9c); other keyboards are left
alone.

Requirements:
  - python-evdev from your distro:
      Debian/Ubuntu: sudo apt install python3-evdev
      Fedora:        sudo dnf install python3-evdev
      Arch:          sudo pacman -S python-evdev
  - root (or read access to /dev/input/event* and write access to /dev/uinput)

Usage:
  sudo ./chatter-filter-linux.py --list              # show input devices and their IDs
  sudo ./chatter-filter-linux.py                     # filter the SDCX keyboard, 40 ms window
  sudo ./chatter-filter-linux.py --threshold 60 --keys E,L,SPACE
  sudo ./chatter-filter-linux.py --device /dev/input/by-id/usb-...-event-kbd

Stop it with Ctrl+C. If the keyboard is unplugged it waits and re-attaches on its own.
"""
import argparse
import asyncio
import os
import sys
from datetime import datetime

try:
    import evdev
    from evdev import ecodes
except ImportError:
    sys.exit("python-evdev is missing. Install it: apt install python3-evdev / "
             "dnf install python3-evdev / pacman -S python-evdev")

# Name prefix of our own virtual devices, so a rescan never grabs them.
VIRTUAL_PREFIX = "chatter-filter: "

log_file = None


def log(msg):
    line = f"{datetime.now():%H:%M:%S.%f}"[:-3] + "  " + msg
    print(line, flush=True)
    if log_file:
        try:
            with open(log_file, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass


def parse_keys(names):
    codes = set()
    for part in ",".join(names).split(","):
        name = part.strip().upper()
        if not name:
            continue
        if not name.startswith("KEY_"):
            name = "KEY_" + name
        code = ecodes.ecodes.get(name)
        if code is None:
            sys.exit(f"Unknown key name: {part.strip()}  (use names like E, L, SPACE, ENTER, LEFTSHIFT)")
        codes.add(code)
    return codes


def key_name(code):
    name = ecodes.KEY.get(code, str(code))
    if isinstance(name, list):
        name = name[0]
    return name.removeprefix("KEY_") if hasattr(name, "removeprefix") else name


class Debouncer:
    """Shared chatter state for every grabbed interface of the keyboard."""

    def __init__(self, threshold_ms, keys):
        self.threshold = threshold_ms / 1000.0
        self.keys = keys            # empty set = all keys
        self.last_up = {}           # code -> release time
        self.suppressed = {}        # code -> time of the dropped press
        self.drops = {}
        self.total = 0

    def filter(self, ev):
        """Return the events to pass on for one input event."""
        if ev.type != ecodes.EV_KEY or (self.keys and ev.code not in self.keys):
            return [ev]
        code, t = ev.code, ev.timestamp()

        if ev.value == 1:                                   # press
            if code in self.suppressed:
                return []
            last = self.last_up.get(code)
            if last is not None and t - last < self.threshold:
                self.suppressed[code] = t
                self.drops[code] = self.drops.get(code, 0) + 1
                self.total += 1
                log(f"dropped {key_name(code):<12} gap {(t - last) * 1000:3.0f} ms  "
                    f"(this key: {self.drops[code]}, total: {self.total})")
                return []
            return [ev]

        if ev.value == 2:                                   # kernel auto-repeat
            since = self.suppressed.get(code)
            if since is None:
                return [ev]
            if t - since <= self.threshold:
                return []
            # The key outlived the window, so it is really being held: send the press now.
            del self.suppressed[code]
            return [evdev.InputEvent(ev.sec, ev.usec, ecodes.EV_KEY, code, 1)]

        if ev.value == 0:                                   # release
            if self.suppressed.pop(code, None) is not None:
                return []
            self.last_up[code] = t
        return [ev]


def list_devices():
    for path in sorted(evdev.list_devices(), key=lambda p: int(p.rsplit("event", 1)[-1])):
        try:
            d = evdev.InputDevice(path)
        except OSError as e:
            print(f"{path}: {e}")
            continue
        kind = "keys" if ecodes.EV_KEY in d.capabilities() else "-"
        print(f"{path:<20} {d.info.vendor:04x}:{d.info.product:04x}  {kind:<5} {d.name}")
        d.close()


def find_devices(args):
    target = os.path.realpath(args.device) if args.device else None
    found = []
    for path in evdev.list_devices():
        try:
            d = evdev.InputDevice(path)
        except OSError:
            continue
        if target:
            match = os.path.realpath(path) == target
        else:
            match = (d.info.vendor == args.vid and d.info.product == args.pid
                     and not d.name.startswith(VIRTUAL_PREFIX))
        if match and ecodes.EV_KEY in d.capabilities():
            found.append(d)
        else:
            d.close()
    return found


async def pump(dev, ui, deb):
    async for ev in dev.async_read_loop():
        for out in deb.filter(ev):
            ui.write_event(out)


async def run_once(args, deb):
    """Grab the keyboard and filter until it disappears. Returns False if it was not found."""
    devices = find_devices(args)
    if not devices:
        return False
    pairs = []
    try:
        for d in devices:
            # Grabbing while a key is held (e.g. Enter that started this script) would leave
            # that key stuck down for the rest of the system.
            while d.active_keys():
                await asyncio.sleep(0.05)
            ui = evdev.UInput.from_device(d, name=VIRTUAL_PREFIX + d.name)
            d.grab()
            pairs.append((d, ui))
            log(f"filtering {d.path}  ({d.name})")
        tasks = [asyncio.ensure_future(pump(d, ui, deb)) for d, ui in pairs]
        try:
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
        finally:
            for t in tasks:
                t.cancel()
        for t in done:
            if not t.cancelled() and t.exception():
                log(f"keyboard lost: {t.exception()}")
    except OSError as e:
        log(f"keyboard lost: {e}")
    finally:
        for d, ui in pairs:
            try:
                d.ungrab()
            except OSError:
                pass
            ui.close()
            d.close()
        for d in devices:
            if all(d is not p for p, _ in pairs):
                d.close()
    return True


async def main_async(args, deb):
    waiting = False
    while True:
        if await run_once(args, deb):
            waiting = False
        elif not waiting:
            log("keyboard not found, waiting for it to be connected...")
            waiting = True
        await asyncio.sleep(2)


def main():
    global log_file
    p = argparse.ArgumentParser(description="Per-key keyboard chatter filter for Linux.")
    p.add_argument("--threshold", type=int, default=40, metavar="MS",
                   help="re-press window in ms treated as chatter (default 40)")
    p.add_argument("--keys", nargs="*", default=[],
                   help="only filter these keys, e.g. --keys E,L,SPACE (default: all keys)")
    p.add_argument("--vid", type=lambda s: int(s, 16), default=0x36AE, help="USB vendor ID in hex (default 36ae)")
    p.add_argument("--pid", type=lambda s: int(s, 16), default=0xFE9C, help="USB product ID in hex (default fe9c)")
    p.add_argument("--device", help="filter this /dev/input/event* path instead of matching vid/pid")
    p.add_argument("--log", help="also append dropped presses to this file")
    p.add_argument("--list", action="store_true", help="list input devices and exit")
    args = p.parse_args()

    if args.list:
        list_devices()
        return
    if not 5 <= args.threshold <= 500:
        sys.exit("--threshold must be between 5 and 500 ms")
    log_file = args.log

    deb = Debouncer(args.threshold, parse_keys(args.keys))
    scope = ", ".join(key_name(c) for c in sorted(deb.keys)) or "all keys"
    target = args.device or f"{args.vid:04x}:{args.pid:04x}"
    log(f"chatter filter running: {target}, {scope}, window {args.threshold} ms. Ctrl+C to stop.")
    try:
        asyncio.run(main_async(args, deb))
    except KeyboardInterrupt:
        pass
    print(f"\nStopped. Dropped {deb.total} chatter press(es) this session.")


if __name__ == "__main__":
    main()
