# Keyboard chatter filter: Linux setup

These instructions are for an AI agent (or a person) setting up the chatter filter
on a Linux PC. Follow the steps in order and run each check before moving on.

## Background

The user's mechanical keyboard (SDCX 68-key, USB ID `36ae:fe9c`, often connected
through a 2.4 GHz receiver) has a worn switch that "chatters": one press sometimes
types the key twice. The keyboard's firmware has no debounce setting, so the fix
is done in software:

- `chatter-filter-linux.py` takes exclusive control of that one keyboard,
  drops any press that comes less than 40 ms after the same key was released
  (that is chatter, not a human), and passes everything else to a virtual keyboard.
  Other keyboards are not touched.
- `install-linux.sh` installs everything as a systemd service (step 6).
- `chatter-filter.service` is the systemd unit, for installing by hand if the installer fails.
- `KeyboardChatterFilter.exe`, `.cs`, `chatter-filter.ps1`, `install.cmd`, `uninstall.cmd`
  and `install.ps1` are the Windows version. Ignore them on Linux.

**Quick path:** a person who doesn't want the guided test can just run
`sudo bash install-linux.sh` and is done. The steps below do the same thing, with a
test-and-tune pass first.

## Safety rules (read first)

- While the filter runs it has the SDCX keyboard to itself. If it hangs, that keyboard
  stops typing. **Always use `timeout` for test runs** (as in step 4) so control
  returns automatically.
- Steps 4 and 5 need the human to type on the keyboard and tell you what they see.
  Ask them, wait for their answer, and do not guess.
- Ask the human before step 6, which installs a system service.
- Install `evdev` from the distro's package manager, not `pip`. The service runs with
  the system Python, which won't see packages installed into a venv or `--user`.

## Step 1: Check the files

From the folder that holds this README:

```bash
ls chatter-filter-linux.py install-linux.sh chatter-filter.service
```

All three files must exist. If they were copied from Windows, make sure they have
Unix line endings (no output from this command means it's fine):

```bash
grep -l $'\r' chatter-filter-linux.py install-linux.sh chatter-filter.service
```

If that lists any files, fix them with `sed -i 's/\r$//' chatter-filter-linux.py install-linux.sh chatter-filter.service`.

## Step 2: Install python-evdev

Find the distro with `. /etc/os-release && echo "$ID $ID_LIKE"`, then run the matching command:

| Distro family | Command |
|---|---|
| Debian, Ubuntu, Mint, Pop!_OS | `sudo apt install -y python3-evdev` |
| Fedora, RHEL-likes | `sudo dnf install -y python3-evdev` |
| Arch, Manjaro, EndeavourOS | `sudo pacman -S --noconfirm python-evdev` |
| openSUSE | `sudo zypper install -y python3-evdev` |

Check it worked:

```bash
python3 -c "import evdev; print('evdev', evdev.__file__)"
```

Make sure the uinput module is loaded (it usually is already):

```bash
sudo modprobe uinput && ls -l /dev/uinput
```

## Step 3: Find the keyboard

```bash
sudo python3 chatter-filter-linux.py --list
```

Look for lines with `36ae:fe9c`. There are usually several (keyboard, media
keys, and so on); that's expected, and the script filters all of them.

- **Found:** continue to step 4.
- **Not found:** ask the human whether the keyboard (or its USB receiver) is
  plugged in and switched to 2.4 GHz/USB mode, then run `--list` again. If the
  keyboard shows up under a different ID (for example over Bluetooth), add `--vid XXXX --pid YYYY`
  with that ID to every command below and to `ExecStart` in the service file.

## Step 4: Test run (needs the human)

Tell the human: *"For the next 60 seconds, please type on the SDCX keyboard,
especially the keys that used to double, then tell me whether they still double."*
Then run:

```bash
sudo timeout 60 python3 chatter-filter-linux.py
```

Expected output:

- A `chatter filter running: 36ae:fe9c, all keys, window 40 ms` line.
- One `filtering /dev/input/eventN (...)` line per keyboard interface.
- `dropped <KEY> gap N ms` lines whenever chatter is caught.

The script waits until no key is held before taking over the keyboard, which is normal.
After 60 seconds it exits by itself and the keyboard goes back to normal.

**Troubleshooting:**

- `Permission denied`: you forgot `sudo`.
- `keyboard not found, waiting...`: go back to step 3.
- A Python traceback: show it to the human, then stop.

## Step 5: Tune (needs the human)

Ask the human how it went, then:

| Human reports | Do |
|---|---|
| Works, no doubles, normal typing fine | Keep `--threshold 40`, go to step 6 |
| A key still doubles sometimes | Retest with `--threshold 60` (then 80 if needed) |
| Real double letters ("ll", "ee") get eaten | Retest with `--threshold 30` |
| Want to filter only the bad keys | Add `--keys E,L` using key names from the `dropped` lines |

Repeat step 4 with the new options until the human is happy. Remember the final options.

## Step 6: Install as a service (ask first)

Run the installer with the options chosen in step 5:

```bash
sudo bash install-linux.sh --threshold 40
```

Add `--keys E,L` (and `--vid`/`--pid` if step 3 needed them) if those were used.
The installer installs evdev if needed, loads `uinput` at boot, copies the script to
`/usr/local/bin`, writes `/etc/systemd/system/chatter-filter.service` with those options,
and enables and starts the service. If it ends with "Filter is running", it worked.
Running it again with other options replaces the settings.

If the installer fails, do the same steps by hand: edit `ExecStart=` in
`chatter-filter.service` to the chosen options, then run:

```bash
sudo install -m 755 chatter-filter-linux.py /usr/local/bin/
sudo cp chatter-filter.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now chatter-filter
```

Check that it's running:

```bash
systemctl is-active chatter-filter
journalctl -u chatter-filter -n 20 --no-pager
```

`is-active` must print `active`, and the log must show the `filtering ...` lines.
Ask the human to type a bit and confirm the keyboard works. Later `dropped` lines
will appear in `journalctl -u chatter-filter -f`.

If `python3` isn't at `/usr/bin/python3` (check with `command -v python3`), fix the
path in `ExecStart`, then run `daemon-reload` and `restart` again.

## Step 7: Report to the human

Tell them:

- The final options used.
- That it starts automatically at boot and re-attaches when the keyboard is unplugged and reconnected.
- How to watch it: `journalctl -u chatter-filter -f`.
- How to stop it temporarily: `sudo systemctl stop chatter-filter`.
- How to remove it (see below).

## Uninstall

```bash
sudo bash install-linux.sh --uninstall
```

## Script options (reference)

```
--threshold MS   re-press window treated as chatter (default 40, range 5-500)
--keys E,L,...   only filter these keys (default: all keys)
--vid / --pid    USB IDs in hex (default 36ae / fe9c)
--device PATH    filter one /dev/input/event* (or /dev/input/by-id/...) path instead
--log FILE       also append dropped presses to FILE
--list           list input devices with their IDs and exit
```
